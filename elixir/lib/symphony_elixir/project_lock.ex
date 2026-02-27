defmodule SymphonyElixir.ProjectLock do
  @moduledoc """
  Prevents multiple Symphony processes on the same host from serving the same
  Linear project at the same time.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.{Config, Workflow}

  @lock_root_name "symphony-project-locks"
  @metadata_file "owner.json"

  @type owner :: %{
          optional(:cwd) => String.t(),
          optional(:details) => String.t(),
          optional(:hostname) => String.t(),
          optional(:instance_id) => String.t(),
          optional(:lock_path) => String.t(),
          optional(:pid) => pos_integer(),
          optional(:project_slug) => String.t(),
          optional(:started_at) => String.t(),
          optional(:workflow_path) => String.t()
        }

  @type state :: %{
          lock_path: String.t() | nil,
          metadata_path: String.t() | nil,
          owner: owner() | nil
        }

  @type pid_probe :: (pos_integer() -> boolean() | :unknown)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    start_opts =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> [name: name]
        :error -> []
      end

    GenServer.start_link(__MODULE__, opts, start_opts)
  end

  @doc false
  @spec lock_path_for_test(String.t(), Path.t()) :: Path.t()
  def lock_path_for_test(project_slug, lock_root) when is_binary(project_slug) and is_binary(lock_root) do
    build_lock_path(Path.expand(lock_root), project_slug)
  end

  @spec duplicate_start_message(map()) :: String.t()
  def duplicate_start_message(owner) when is_map(owner) do
    owner = normalize_owner(owner)

    message_prefix(owner) <>
      pid_segment(owner) <>
      workflow_segment(owner) <>
      cwd_segment(owner) <>
      detail_segment(owner)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case acquire_lock(runtime_config(opts)) do
      {:ok, state} ->
        {:ok, state}

      {:error, {:project_already_running, owner} = reason} ->
        Logger.error(duplicate_start_message(owner))
        {:stop, reason}

      {:error, {:project_lock_unavailable, project_slug, lock_path, lock_reason} = reason} ->
        Logger.error(lock_unavailable_message(project_slug, lock_path, lock_reason))
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{lock_path: nil}), do: :ok

  def terminate(_reason, %{lock_path: lock_path, metadata_path: metadata_path, owner: owner}) do
    release_lock(lock_path, metadata_path, owner)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp runtime_config(opts) do
    tracker_kind = Keyword.get_lazy(opts, :tracker_kind, &Config.tracker_kind/0)
    project_slug = Keyword.get_lazy(opts, :project_slug, &Config.linear_project_slug/0)
    lock_root = opts |> Keyword.get(:lock_root, default_lock_root()) |> Path.expand()
    pid_probe = Keyword.get(opts, :pid_alive?, &os_pid_alive?/1)

    owner = %{
      instance_id: Keyword.get(opts, :instance_id, random_instance_id()),
      project_slug: project_slug,
      hostname: Keyword.get(opts, :hostname, hostname()),
      pid: opts |> Keyword.get(:os_pid, System.pid()) |> normalize_pid(),
      workflow_path: Keyword.get(opts, :workflow_path, Workflow.workflow_file_path()),
      cwd: Keyword.get_lazy(opts, :cwd, &File.cwd!/0),
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
    }

    %{lock_root: lock_root, owner: owner, pid_probe: pid_probe, tracker_kind: tracker_kind}
  end

  defp acquire_lock(%{tracker_kind: "linear", owner: %{project_slug: project_slug} = owner} = config)
       when is_binary(project_slug) and project_slug != "" do
    lock_path = build_lock_path(config.lock_root, project_slug)
    metadata_path = Path.join(lock_path, @metadata_file)
    owner = Map.put(owner, :lock_path, lock_path)

    case File.mkdir_p(config.lock_root) do
      :ok ->
        do_acquire_lock(lock_path, metadata_path, owner, config.pid_probe)

      {:error, reason} ->
        {:error, {:project_lock_unavailable, project_slug, lock_path, reason}}
    end
  end

  defp acquire_lock(_config), do: {:ok, %{lock_path: nil, metadata_path: nil, owner: nil}}

  defp do_acquire_lock(lock_path, metadata_path, owner, pid_probe) do
    project_slug = Map.fetch!(owner, :project_slug)

    case File.mkdir(lock_path) do
      :ok ->
        case write_owner(metadata_path, owner) do
          :ok ->
            {:ok, %{lock_path: lock_path, metadata_path: metadata_path, owner: owner}}

          {:error, reason} ->
            remove_lock_dir(lock_path)
            {:error, {:project_lock_unavailable, project_slug, lock_path, reason}}
        end

      {:error, :eexist} ->
        recover_or_reject_existing_lock(lock_path, metadata_path, owner, pid_probe)

      {:error, reason} ->
        {:error, {:project_lock_unavailable, project_slug, lock_path, reason}}
    end
  end

  defp recover_or_reject_existing_lock(lock_path, metadata_path, owner, pid_probe) do
    project_slug = Map.fetch!(owner, :project_slug)

    case read_owner(metadata_path) do
      {:ok, existing_owner} ->
        handle_existing_owner(existing_owner, lock_path, metadata_path, owner, pid_probe)

      {:error, reason} ->
        {:error, existing_lock_metadata_error(project_slug, lock_path, reason)}
    end
  end

  defp handle_existing_owner(existing_owner, lock_path, metadata_path, owner, pid_probe) do
    existing_owner = Map.put(existing_owner, :lock_path, lock_path)

    if stale_owner?(existing_owner, pid_probe) do
      recover_stale_lock(lock_path, metadata_path, owner, pid_probe)
    else
      {:error, {:project_already_running, existing_owner}}
    end
  end

  defp recover_stale_lock(lock_path, metadata_path, owner, pid_probe) do
    project_slug = Map.fetch!(owner, :project_slug)
    Logger.warning("Removing stale project lock for Linear project #{project_slug} at #{lock_path}")

    case remove_lock_dir(lock_path) do
      :ok ->
        do_acquire_lock(lock_path, metadata_path, owner, pid_probe)

      {:error, reason} ->
        {:error, {:project_lock_unavailable, project_slug, lock_path, reason}}
    end
  end

  defp write_owner(metadata_path, owner) do
    owner
    |> owner_payload()
    |> Jason.encode()
    |> case do
      {:ok, payload} -> File.write(metadata_path, payload)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_owner(metadata_path) do
    with {:ok, payload} <- File.read(metadata_path),
         {:ok, owner} <- Jason.decode(payload) do
      {:ok, normalize_owner(owner)}
    end
  end

  defp release_lock(lock_path, metadata_path, owner) when is_binary(lock_path) and is_map(owner) do
    with {:ok, current_owner} <- read_owner(metadata_path),
         true <- same_owner?(current_owner, owner) do
      case remove_lock_dir(lock_path) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to release project lock #{lock_path}: #{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  end

  defp release_lock(_lock_path, _metadata_path, _owner), do: :ok

  defp remove_lock_dir(lock_path) do
    case File.rm_rf(lock_path) do
      {:ok, _paths} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp stale_owner?(owner, pid_probe) do
    case Map.get(owner, :pid) do
      pid when is_integer(pid) and pid > 0 ->
        case pid_probe.(pid) do
          false -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp same_owner?(owner_a, owner_b) do
    Map.get(normalize_owner(owner_a), :instance_id) ==
      Map.get(normalize_owner(owner_b), :instance_id)
  end

  defp owner_payload(owner) do
    owner
    |> normalize_owner()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_owner(owner) do
    %{
      instance_id: get_owner_field(owner, :instance_id),
      project_slug: get_owner_field(owner, :project_slug),
      hostname: get_owner_field(owner, :hostname),
      pid: owner |> get_owner_field(:pid) |> normalize_pid(),
      workflow_path: get_owner_field(owner, :workflow_path),
      cwd: get_owner_field(owner, :cwd),
      started_at: get_owner_field(owner, :started_at),
      lock_path: get_owner_field(owner, :lock_path),
      details: get_owner_field(owner, :details)
    }
  end

  defp get_owner_field(owner, field) when is_map(owner) do
    Map.get(owner, field) || Map.get(owner, Atom.to_string(field))
  end

  defp normalize_pid(pid) when is_integer(pid) and pid > 0, do: pid

  defp normalize_pid(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp normalize_pid(_pid), do: nil

  defp lock_unavailable_message(project_slug, lock_path, reason) do
    "could not acquire startup lock for Linear project #{project_slug} at #{lock_path}: #{inspect(reason)}"
  end

  defp message_prefix(owner) do
    project_slug = Map.get(owner, :project_slug, "unknown")
    hostname = Map.get(owner, :hostname, "unknown host")

    "another Symphony process is already serving Linear project #{project_slug} on #{hostname}"
  end

  defp pid_segment(%{pid: pid}) when is_integer(pid) and pid > 0, do: " (pid #{pid})"
  defp pid_segment(_owner), do: ""

  defp workflow_segment(%{workflow_path: path}) when is_binary(path) and path != "", do: " using #{path}"
  defp workflow_segment(_owner), do: ""

  defp cwd_segment(%{cwd: path}) when is_binary(path) and path != "", do: " from #{path}"
  defp cwd_segment(_owner), do: ""

  defp detail_segment(%{details: value}) when is_binary(value) and value != "", do: "; #{value}"
  defp detail_segment(_owner), do: ""

  defp existing_lock_metadata_error(project_slug, lock_path, reason) do
    {:project_already_running,
     %{
       project_slug: project_slug,
       lock_path: lock_path,
       details: "startup lock exists but owner metadata is unavailable (#{inspect(reason)})"
     }}
  end

  defp default_lock_root, do: Path.join(System.tmp_dir!(), @lock_root_name)

  defp build_lock_path(lock_root, project_slug) do
    suffix =
      :crypto.hash(:sha256, project_slug)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    prefix =
      project_slug
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/u, "-")
      |> String.trim("-")
      |> case do
        "" -> "project"
        value -> String.slice(value, 0, 40)
      end

    Path.join(lock_root, "#{prefix}-#{suffix}")
  end

  defp random_instance_id do
    :crypto.strong_rand_bytes(8)
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec hostname_for_test((-> {:ok, charlist() | String.t()} | term())) :: String.t()
  def hostname_for_test(gethostname_fun \\ &:inet.gethostname/0) do
    case gethostname_fun.() do
      {:ok, hostname} -> to_string(hostname)
      _ -> "unknown-host"
    end
  end

  defp hostname, do: hostname_for_test()

  @doc false
  @spec os_pid_alive_for_test(integer() | term()) :: boolean() | :unknown
  def os_pid_alive_for_test(pid), do: os_pid_alive_for_test(pid, &System.find_executable/1, &System.cmd/3)

  @doc false
  @spec os_pid_alive_for_test(
          integer() | term(),
          (String.t() -> String.t() | nil),
          (String.t(), [String.t()], keyword() -> {String.t(), integer()})
        ) :: boolean() | :unknown
  def os_pid_alive_for_test(pid, find_executable_fun, system_cmd_fun)
      when is_integer(pid) and pid > 0 do
    case find_executable_fun.("kill") do
      nil ->
        :unknown

      kill_binary ->
        case system_cmd_fun.(kill_binary, ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_output, 0} -> true
          {_output, _status} -> false
        end
    end
  end

  def os_pid_alive_for_test(_pid, _find_executable_fun, _system_cmd_fun), do: :unknown

  defp os_pid_alive?(pid), do: os_pid_alive_for_test(pid)
end
