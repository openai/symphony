defmodule SymphonyElixir.StatusDashboardSnapshotTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TestSupport.Snapshot

  @terminal_columns 115

  test "snapshot fixture: idle dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    Snapshot.assert_dashboard_snapshot!("idle", render_snapshot(snapshot_data, 0.0))
  end

  test "snapshot fixture: idle dashboard with observability url" do
    previous_port_override = Application.get_env(:symphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:symphony_elixir, :server_port_override)
      else
        Application.put_env(:symphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:symphony_elixir, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    Snapshot.assert_dashboard_snapshot!("idle_with_dashboard_url", render_snapshot(snapshot_data, 0.0))
  end

  test "snapshot fixture: super busy dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-101",
             codex_total_tokens: 120_450,
             runtime_seconds: 785,
             turn_count: 11,
             last_codex_event: "turn_completed",
             last_codex_message: turn_completed_message("completed")
           }),
           running_entry(%{
             identifier: "MT-102",
             session_id: "thread-abcdef1234567890",
             codex_app_server_pid: "5252",
             codex_total_tokens: 89_200,
             runtime_seconds: 412,
             turn_count: 4,
             last_codex_event: "codex/event/task_started",
             last_codex_message: exec_command_message("mix test --cover")
           })
         ],
         retrying: [],
         codex_totals: %{
           input_tokens: 250_000,
           output_tokens: 18_500,
           total_tokens: 268_500,
           seconds_running: 4_321
         },
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 12_345, limit: 20_000, reset_in_seconds: 30},
           secondary: %{remaining: 45, limit: 60, reset_in_seconds: 12},
           credits: %{has_credits: true, balance: 9_876.5}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("super_busy", render_snapshot(snapshot_data, 1_842.7))
  end

  test "snapshot fixture: backoff queue pressure" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-638",
             state: "retrying",
             codex_total_tokens: 14_200,
             runtime_seconds: 1_225,
             turn_count: 7,
             last_codex_event: :notification,
             last_codex_message: agent_message_delta("waiting on rate-limit backoff window")
           })
         ],
         retrying: [
           retry_entry(%{
             identifier: "MT-450",
             attempt: 4,
             due_in_ms: 1_250,
             error: "rate limit exhausted"
           }),
           retry_entry(%{
             identifier: "MT-451",
             attempt: 2,
             due_in_ms: 3_900,
             error: "retrying after API timeout with jitter"
           }),
           retry_entry(%{
             identifier: "MT-452",
             attempt: 6,
             due_in_ms: 8_100,
             error: "worker crashed\nrestarting cleanly"
           }),
           retry_entry(%{
             identifier: "MT-453",
             attempt: 1,
             due_in_ms: 11_000,
             error: "fourth queued retry should also render after removing the top-three limit"
           })
         ],
         codex_totals: %{input_tokens: 18_000, output_tokens: 2_200, total_tokens: 20_200, seconds_running: 2_700},
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 0, limit: 20_000, reset_in_seconds: 95},
           secondary: %{remaining: 0, limit: 60, reset_in_seconds: 45},
           credits: %{has_credits: false}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("backoff_queue", render_snapshot(snapshot_data, 15.4))
  end

  test "backoff queue row escapes escaped newline sequences" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [
           retry_entry(%{
             identifier: "MT-980",
             attempt: 1,
             due_in_ms: 1_500,
             error: "error with \\nnewline"
           })
         ],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)
    backoff_lines = rendered |> String.split("\n") |> Enum.filter(&String.contains?(&1, "MT-980"))

    assert length(backoff_lines) == 1

    [backoff_line] = backoff_lines

    assert backoff_line =~ "error=error with newline"
    refute backoff_line =~ "\\n"
  end

  test "snapshot fixture: unlimited credits variant" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-777",
             state: "running",
             codex_total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_codex_event: "codex/event/token_count",
             last_codex_message: token_usage_message(90, 12, 102)
           })
         ],
         retrying: [],
         codex_totals: %{input_tokens: 90, output_tokens: 12, total_tokens: 102, seconds_running: 75},
         rate_limits: %{
           limit_id: "priority-tier",
           primary: %{remaining: 100, limit: 100, reset_in_seconds: 1},
           secondary: %{remaining: 500, limit: 500, reset_in_seconds: 1},
           credits: %{unlimited: true}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("credits_unlimited", render_snapshot(snapshot_data, 42.0))
  end

  defp render_snapshot(snapshot_data, tps) do
    StatusDashboard.format_snapshot_content_for_test(snapshot_data, tps, @terminal_columns)
  end

  defp running_entry(overrides) do
    Map.merge(
      %{
        identifier: "MT-000",
        state: "running",
        session_id: "thread-1234567890",
        codex_app_server_pid: "4242",
        codex_total_tokens: 0,
        runtime_seconds: 0,
        turn_count: 1,
        last_codex_event: :notification,
        last_codex_message: turn_started_message()
      },
      overrides
    )
  end

  defp retry_entry(overrides) do
    Map.merge(
      %{
        issue_id: "issue-1",
        identifier: "MT-000",
        attempt: 1,
        due_in_ms: 1_000,
        error: "retry scheduled"
      },
      overrides
    )
  end

  defp turn_started_message do
    %{
      event: :notification,
      message: %{
        "method" => "turn/started",
        "params" => %{"turn" => %{"id" => "turn-1"}}
      }
    }
  end

  defp turn_completed_message(status) do
    %{
      event: :notification,
      message: %{
        "method" => "turn/completed",
        "params" => %{"turn" => %{"status" => status}}
      }
    }
  end

  defp exec_command_message(command) do
    %{
      event: :notification,
      message: %{
        "method" => "codex/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => command}}
      }
    }
  end

  defp agent_message_delta(delta) do
    %{
      event: :notification,
      message: %{
        "method" => "codex/event/agent_message_delta",
        "params" => %{"msg" => %{"payload" => %{"delta" => delta}}}
      }
    }
  end

  defp token_usage_message(input_tokens, output_tokens, total_tokens) do
    %{
      event: :notification,
      message: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{
              "inputTokens" => input_tokens,
              "outputTokens" => output_tokens,
              "totalTokens" => total_tokens
            }
          }
        }
      }
    }
  end
end
