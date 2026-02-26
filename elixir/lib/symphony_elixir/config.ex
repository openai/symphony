defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Workflow

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_workspace_root Path.join(System.tmp_dir!(), "symphony_workspaces")
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_max_retry_backoff_ms 300_000
  @default_codex_command "codex app-server"
  @default_server_host "127.0.0.1"

  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    fetch_string([["tracker", "kind"]], nil)
    |> normalize_tracker_kind()
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint do
    fetch_string([["tracker", "endpoint"]], @default_linear_endpoint)
  end

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token do
    [["tracker", "api_key"]]
    |> fetch_value(:missing)
    |> resolve_env_value(System.get_env("LINEAR_API_KEY"))
    |> normalize_secret_value()
  end

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug do
    fetch_string([["tracker", "project_slug"]], nil)
  end

  @spec linear_active_states() :: [String.t()]
  def linear_active_states do
    fetch_csv([["tracker", "active_states"]], @default_active_states)
  end

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states do
    fetch_csv([["tracker", "terminal_states"]], @default_terminal_states)
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    fetch_integer([["polling", "interval_ms"]], 30_000)
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    fetch_path([["workspace", "root"]], @default_workspace_root)
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    %{
      after_create: fetch_hook_command("after_create"),
      before_run: fetch_hook_command("before_run"),
      after_run: fetch_hook_command("after_run"),
      before_remove: fetch_hook_command("before_remove"),
      timeout_ms: hook_timeout_ms()
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    case fetch_integer([["hooks", "timeout_ms"]], @default_hook_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms

      _ ->
        @default_hook_timeout_ms
    end
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    fetch_integer([["agent", "max_concurrent_agents"]], @default_max_concurrent_agents)
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    case fetch_integer([["agent", "max_retry_backoff_ms"]], @default_max_retry_backoff_ms) do
      backoff_ms when is_integer(backoff_ms) and backoff_ms > 0 ->
        backoff_ms

      _ ->
        @default_max_retry_backoff_ms
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits =
      state_limits_by_name(fetch_map([["agent", "max_concurrent_agents_by_state"]], %{}))

    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec codex_command() :: String.t()
  def codex_command do
    case fetch_value([["codex", "command"]], :missing) do
      command when is_binary(command) ->
        case String.trim(command) do
          "" -> @default_codex_command
          trimmed -> trimmed
        end

      _ ->
        @default_codex_command
    end
  end

  @spec codex_turn_timeout_ms() :: pos_integer()
  def codex_turn_timeout_ms do
    fetch_integer([["codex", "turn_timeout_ms"]], 3_600_000)
  end

  @spec codex_read_timeout_ms() :: pos_integer()
  def codex_read_timeout_ms do
    fetch_integer([["codex", "read_timeout_ms"]], 5_000)
  end

  @spec codex_stall_timeout_ms() :: non_neg_integer()
  def codex_stall_timeout_ms do
    max(fetch_integer([["codex", "stall_timeout_ms"]], 300_000), 0)
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    fetch_boolean([["observability", "dashboard_enabled"]], true)
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    fetch_integer([["observability", "refresh_ms"]], 1_000)
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    fetch_integer([["observability", "render_interval_ms"]], 16)
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        case fetch_integer([["server", "port"]], -1) do
          port when is_integer(port) and port >= 0 -> port
          _ -> nil
        end
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    fetch_string([["server", "host"]], @default_server_host)
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, _workflow} <- current_workflow(),
         :ok <- require_tracker_kind(),
         :ok <- require_linear_token(),
         :ok <- require_linear_project() do
      require_codex_command()
    end
  end

  defp require_tracker_kind do
    case tracker_kind() do
      "linear" -> :ok
      "memory" -> :ok
      nil -> {:error, :missing_tracker_kind}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp require_linear_token do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_api_token()) do
          :ok
        else
          {:error, :missing_linear_api_token}
        end

      _ ->
        :ok
    end
  end

  defp require_linear_project do
    case tracker_kind() do
      "linear" ->
        if is_binary(linear_project_slug()) do
          :ok
        else
          {:error, :missing_linear_project_slug}
        end

      _ ->
        :ok
    end
  end

  defp require_codex_command do
    if byte_size(String.trim(codex_command())) > 0 do
      :ok
    else
      {:error, :missing_codex_command}
    end
  end

  defp fetch_value(paths, default) do
    config = workflow_config()

    case resolve_config_value(config, paths) do
      :missing -> default
      value -> value
    end
  end

  defp fetch_string(paths, default) do
    case fetch_value(paths, :missing) do
      :missing -> default
      nil -> default
      value when is_binary(value) -> String.trim(value)
      value -> to_string(value)
    end
  end

  defp fetch_path(paths, default) do
    resolve_path_value(fetch_value(paths, :missing), default)
  end

  defp fetch_integer(paths, default) do
    fetch_value(paths, :missing)
    |> case do
      :missing ->
        default

      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, _} -> parsed
          :error -> default
        end

      _ ->
        default
    end
  end

  defp fetch_boolean(paths, default) do
    fetch_value(paths, :missing)
    |> case do
      :missing ->
        default

      value when is_boolean(value) ->
        value

      value when is_binary(value) ->
        case String.downcase(String.trim(value)) do
          "true" -> true
          "false" -> false
          _ -> default
        end

      _ ->
        default
    end
  end

  defp fetch_map(paths, default) do
    fetch_value(paths, :missing)
    |> case do
      :missing -> default
      value when is_map(value) -> value
      _ -> default
    end
  end

  defp fetch_csv(paths, default) do
    fetch_value(paths, :missing)
    |> case do
      :missing ->
        default

      values when is_list(values) ->
        values
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> default
          parsed_values -> parsed_values
        end

      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> default
          parsed_values -> parsed_values
        end

      _ ->
        default
    end
  end

  defp fetch_hook_command(hook_name) when is_binary(hook_name) do
    case fetch_value([["hooks", hook_name]], :missing) do
      :missing ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          _ -> String.trim_trailing(value)
        end

      _ ->
        nil
    end
  end

  defp state_limits_by_name(raw_limits) when is_map(raw_limits) do
    Enum.reduce(raw_limits, %{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, value} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), value)

        :error ->
          acc
      end
    end)
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0 do
    {:ok, value}
  end

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_positive_integer(_value), do: :error

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp workflow_config do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        normalize_keys(config)

      _ ->
        %{}
    end
  end

  defp resolve_config_value(%{} = config, paths) do
    Enum.reduce_while(paths, :missing, fn path, _acc ->
      case get_in_path(config, path) do
        :missing -> {:cont, :missing}
        value -> {:halt, value}
      end
    end)
  end

  defp get_in_path(config, path) when is_list(path) and is_map(config) do
    get_in_path(config, path, 0)
  end

  defp get_in_path(_, _), do: :missing

  defp get_in_path(config, [], _depth), do: config

  defp get_in_path(%{} = current, [segment | rest], _depth) do
    case Map.fetch(current, normalize_key(segment)) do
      {:ok, value} -> get_in_path(value, rest, 0)
      :error -> :missing
    end
  end

  defp get_in_path(_, _, _depth), do: :missing

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_path_value(:missing, default), do: default
  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name()
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp preserve_command_name(path) do
    cond do
      uri_path?(path) ->
        path

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        Path.expand(path)

      true ->
        path
    end
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp resolve_env_value(:missing, fallback), do: fallback
  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret_value(_value), do: nil
end
