defmodule SymphonyElixir.SupervisorSnapshot do
  @moduledoc """
  Reconciles workspace-local supervisor status snapshots with fresh tracker state.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue, Workspace}

  @status_relative_path Path.join([".artifacts", "symphony", "supervisor-status.json"])
  @stale_hold_states MapSet.new(["blocked", "human-review"])

  @spec reconcile_candidate_snapshots([Issue.t()]) :: [Issue.t()]
  def reconcile_candidate_snapshots(issues) when is_list(issues) do
    Enum.each(issues, &reconcile_candidate_snapshot/1)
    issues
  end

  @spec status_relative_path() :: Path.t()
  def status_relative_path, do: @status_relative_path

  defp reconcile_candidate_snapshot(%Issue{} = issue) do
    with {:ok, workspace} <- Workspace.existing_issue_workspace(issue),
         status_path <- Path.join(workspace, @status_relative_path),
         {:ok, snapshot} <- read_snapshot(status_path),
         true <- stale_hold_snapshot?(snapshot, issue) do
      write_reconciled_snapshot(status_path, snapshot, issue)
    else
      _ -> :ok
    end
  end

  defp reconcile_candidate_snapshot(_issue), do: :ok

  defp read_snapshot(status_path) when is_binary(status_path) do
    with {:ok, body} <- File.read(status_path),
         {:ok, snapshot} when is_map(snapshot) <- Jason.decode(body) do
      {:ok, snapshot}
    else
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp stale_hold_snapshot?(snapshot, %Issue{} = issue) when is_map(snapshot) do
    hold_snapshot_state?(Map.get(snapshot, "state")) and issue_dispatchable?(issue)
  end

  defp hold_snapshot_state?(state) when is_binary(state) do
    MapSet.member?(@stale_hold_states, normalize_state(state))
  end

  defp hold_snapshot_state?(_state), do: false

  defp issue_dispatchable?(%Issue{state: state, blocked_by: blockers}) when is_binary(state) do
    active_issue_state?(state) and !blocked_by_non_terminal?(blockers)
  end

  defp issue_dispatchable?(_issue), do: false

  defp active_issue_state?(state) when is_binary(state) do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_state/1)
    |> MapSet.new()
    |> MapSet.member?(normalize_state(state))
  end

  defp blocked_by_non_terminal?(blockers) when is_list(blockers) do
    terminal_states =
      Config.settings!().tracker.terminal_states
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    Enum.any?(blockers, fn
      %{state: blocker_state} when is_binary(blocker_state) ->
        !MapSet.member?(terminal_states, normalize_state(blocker_state))

      _ ->
        true
    end)
  end

  defp blocked_by_non_terminal?(_blockers), do: false

  defp write_reconciled_snapshot(status_path, snapshot, %Issue{} = issue) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload =
      snapshot
      |> Map.merge(%{
        "state" => "idle",
        "linear_state" => issue.state,
        "active_worker" => nil,
        "last_heartbeat" => now,
        "recent_failure" => "none",
        "status_artifact" => @status_relative_path,
        "reconciliation_reason" => "linear-state-newer-than-supervisor-snapshot",
        "reconciled_from" => %{
          "state" => Map.get(snapshot, "state"),
          "linear_state" => Map.get(snapshot, "linear_state"),
          "recent_failure" => Map.get(snapshot, "recent_failure")
        },
        "reconciled_at" => now
      })

    File.mkdir_p!(Path.dirname(status_path))
    File.write!(status_path, Jason.encode!(payload, pretty: true) <> "\n")

    Logger.info("Reconciled stale supervisor snapshot issue_id=#{issue.id} issue_identifier=#{issue.identifier} linear_state=#{issue.state} status_path=#{status_path}")

    :ok
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end
end
