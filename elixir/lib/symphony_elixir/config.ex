defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

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

  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow, do: Workflow.current()

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind, do: get_setting!([:tracker, :kind])

  @spec linear_endpoint() :: String.t()
  def linear_endpoint, do: get_setting!([:tracker, :endpoint])

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token, do: get_setting!([:tracker, :api_key])

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug, do: get_setting!([:tracker, :project_slug])

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee, do: get_setting!([:tracker, :assignee])

  @spec linear_active_states() :: [String.t()]
  def linear_active_states, do: get_setting!([:tracker, :active_states])

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states, do: get_setting!([:tracker, :terminal_states])

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms, do: get_setting!([:polling, :interval_ms])

  @spec workspace_root() :: Path.t()
  def workspace_root, do: get_setting!([:workspace, :root])

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks, do: get_setting!([:hooks])

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms, do: get_setting!([:hooks, :timeout_ms])

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents, do: get_setting!([:agent, :max_concurrent_agents])

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms, do: get_setting!([:agent, :max_retry_backoff_ms])

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns, do: get_setting!([:agent, :max_turns])

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_setting!([:agent, :max_concurrent_agents_by_state])
    Map.get(state_limits, Schema.normalize_issue_state(state_name), max_concurrent_agents())
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec codex_command() :: String.t()
  def codex_command, do: get_setting!([:codex, :command])

  @spec codex_turn_timeout_ms() :: pos_integer()
  def codex_turn_timeout_ms, do: get_setting!([:codex, :turn_timeout_ms])

  @spec codex_approval_policy() :: String.t() | map()
  def codex_approval_policy, do: get_setting!([:codex, :approval_policy])

  @spec codex_thread_sandbox() :: String.t()
  def codex_thread_sandbox, do: get_setting!([:codex, :thread_sandbox])

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    validated_settings!()
    |> Schema.resolve_turn_sandbox_policy(workspace)
  end

  @spec codex_read_timeout_ms() :: pos_integer()
  def codex_read_timeout_ms, do: get_setting!([:codex, :read_timeout_ms])

  @spec codex_stall_timeout_ms() :: non_neg_integer()
  def codex_stall_timeout_ms, do: get_setting!([:codex, :stall_timeout_ms])

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
  def observability_enabled?, do: get_setting!([:observability, :dashboard_enabled])

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms, do: get_setting!([:observability, :refresh_ms])

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms, do: get_setting!([:observability, :render_interval_ms])

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> get_setting!([:server, :port])
    end
  end

  @spec server_host() :: String.t()
  def server_host, do: get_setting!([:server, :host])

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- validated_settings(),
         :ok <- require_tracker_kind(settings),
         :ok <- require_linear_token(settings),
         :ok <- require_linear_project(settings) do
      require_codex_command(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil) :: {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil) do
    with {:ok, settings} <- validated_settings() do
      {:ok,
       %{
         approval_policy: get_in(settings, [:codex, :approval_policy]),
         thread_sandbox: get_in(settings, [:codex, :thread_sandbox]),
         turn_sandbox_policy: Schema.resolve_turn_sandbox_policy(settings, workspace)
       }}
    end
  end

  defp get_setting!(path) do
    validated_settings!()
    |> get_in(path)
  end

  defp validated_settings! do
    case validated_settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  defp validated_settings do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:ok, _workflow} ->
        Schema.parse(%{})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_tracker_kind(settings) do
    case get_in(settings, [:tracker, :kind]) do
      "linear" -> :ok
      "memory" -> :ok
      nil -> {:error, :missing_tracker_kind}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp require_linear_token(settings) do
    case get_in(settings, [:tracker, :kind]) do
      "linear" ->
        if is_binary(get_in(settings, [:tracker, :api_key])) do
          :ok
        else
          {:error, :missing_linear_api_token}
        end

      _ ->
        :ok
    end
  end

  defp require_linear_project(settings) do
    case get_in(settings, [:tracker, :kind]) do
      "linear" ->
        if is_binary(get_in(settings, [:tracker, :project_slug])) do
          :ok
        else
          {:error, :missing_linear_project_slug}
        end

      _ ->
        :ok
    end
  end

  defp require_codex_command(settings) do
    if is_binary(get_in(settings, [:codex, :command])) do
      :ok
    else
      {:error, :missing_codex_command}
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
