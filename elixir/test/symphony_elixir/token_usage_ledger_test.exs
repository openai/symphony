defmodule SymphonyElixir.TokenUsageLedgerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias SymphonyElixir.TokenUsageLedger

  setup do
    previous_ledger_file = Application.get_env(:symphony_elixir, :token_usage_ledger_file)
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-token-usage-ledger-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    ledger_file = Path.join(test_root, "token_usage.jsonl")

    on_exit(fn ->
      restore_app_env(:token_usage_ledger_file, previous_ledger_file)
      restore_app_env(:log_file, previous_log_file)
      File.rm_rf(test_root)
    end)

    {:ok, ledger_file: ledger_file, test_root: test_root}
  end

  test "default ledger path is next to the configured log file", %{test_root: test_root} do
    Application.delete_env(:symphony_elixir, :token_usage_ledger_file)
    Application.put_env(:symphony_elixir, :log_file, Path.join(test_root, "log/symphony.log"))

    assert TokenUsageLedger.file_path() == Path.join(test_root, "log/token_usage.jsonl")

    Application.put_env(:symphony_elixir, :token_usage_ledger_file, Path.join(test_root, "custom.jsonl"))
    assert TokenUsageLedger.file_path() == Path.join(test_root, "custom.jsonl")
  end

  test "appends valid JSONL records", %{ledger_file: ledger_file} do
    assert :ok =
             TokenUsageLedger.append_observation(
               %{
                 observed_at: ~U[2026-04-20 10:00:00Z],
                 final: false,
                 issue_id: "issue-1",
                 issue_identifier: "MT-1",
                 session_id: "thread-1-turn-1",
                 worker_host: "worker-a",
                 workspace_path: "/tmp/MT-1",
                 turn_count: 1,
                 input_tokens: 10,
                 output_tokens: 5,
                 total_tokens: 15,
                 source_event: :notification
               },
               file: ledger_file
             )

    assert [
             %{
               "schema_version" => 1,
               "observed_at" => "2026-04-20T10:00:00Z",
               "final" => false,
               "issue_id" => "issue-1",
               "issue_identifier" => "MT-1",
               "session_id" => "thread-1-turn-1",
               "worker_host" => "worker-a",
               "workspace_path" => "/tmp/MT-1",
               "turn_count" => 1,
               "input_tokens" => 10,
               "output_tokens" => 5,
               "total_tokens" => 15,
               "source_event" => "notification"
             }
           ] =
             ledger_file
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)
  end

  test "summarizes max token totals per issue and session", %{ledger_file: ledger_file} do
    append!(ledger_file, "MT-1", "session-a", 100, 20, 120)
    append!(ledger_file, "MT-1", "session-a", 90, 10, 100)
    append!(ledger_file, "MT-1", "session-b", 30, 5, 35)
    append!(ledger_file, "MT-2", "session-c", 7, 3, 10)

    assert TokenUsageLedger.summary(file: ledger_file) == %{
             input_tokens: 137,
             output_tokens: 28,
             total_tokens: 165,
             issue_count: 2,
             session_count: 3
           }

    assert TokenUsageLedger.issue_summary("MT-1", file: ledger_file) == %{
             issue_id: "issue-MT-1",
             issue_identifier: "MT-1",
             worker_host: nil,
             workspace_path: "/tmp/MT-1",
             input_tokens: 130,
             output_tokens: 25,
             total_tokens: 155,
             session_count: 2
           }
  end

  test "ignores malformed and unreadable ledger records", %{ledger_file: ledger_file} do
    File.write!(
      ledger_file,
      [
        "not json",
        "[]",
        Jason.encode!(%{"schema_version" => 2, "issue_identifier" => "MT-0"}),
        Jason.encode!(%{"schema_version" => 1, "issue_identifier" => "MT-0"}),
        ""
      ]
      |> Enum.join("\n")
    )

    append!(ledger_file, "MT-3", "session-d", 1, 2, 3)

    assert TokenUsageLedger.summary(file: ledger_file) == %{
             input_tokens: 1,
             output_tokens: 2,
             total_tokens: 3,
             issue_count: 1,
             session_count: 1
           }

    missing_file = Path.join(Path.dirname(ledger_file), "missing.jsonl")
    assert TokenUsageLedger.read_records(file: missing_file) == []
    assert TokenUsageLedger.issue_summary("MT-MISSING", file: ledger_file) == nil
  end

  test "normalizes invalid token field values", %{ledger_file: ledger_file} do
    File.write!(
      ledger_file,
      Jason.encode!(%{
        "schema_version" => 1,
        "issue_identifier" => "MT-0",
        "session_id" => "session-zero",
        "final" => "not-a-bool",
        "input_tokens" => "bad",
        "output_tokens" => -2,
        "total_tokens" => 0
      })
    )

    assert [
             %{
               final: false,
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0
             }
           ] = TokenUsageLedger.read_records(file: ledger_file)
  end

  test "reads configured ledger path and normalizes string token values", %{ledger_file: ledger_file} do
    Application.put_env(:symphony_elixir, :token_usage_ledger_file, ledger_file)

    File.write!(
      ledger_file,
      Jason.encode!(%{
        "schema_version" => 1,
        "issue_identifier" => "MT-STRING",
        "session_id" => "session-string",
        "input_tokens" => "4",
        "output_tokens" => "1",
        "total_tokens" => "5",
        "source_event" => []
      })
    )

    assert [
             %{
               issue_identifier: "MT-STRING",
               session_id: "session-string",
               input_tokens: 4,
               output_tokens: 1,
               total_tokens: 5,
               source_event: nil
             }
           ] = TokenUsageLedger.read_records()
  end

  test "write failures are logged but do not crash", %{test_root: test_root} do
    log =
      capture_log(fn ->
        assert :ok =
                 TokenUsageLedger.append_observation(
                   %{
                     issue_identifier: "MT-ERR",
                     session_id: "session-error",
                     input_tokens: 1,
                     output_tokens: 0,
                     total_tokens: 1
                   },
                   file: test_root
                 )
      end)

    assert log =~ "Failed to append token usage ledger record"

    log =
      capture_log(fn ->
        assert :ok =
                 TokenUsageLedger.append_observation(
                   %{
                     issue_id: 123,
                     issue_identifier: "MT-ERR",
                     session_id: "session-error",
                     source_event: 456,
                     input_tokens: 1,
                     output_tokens: 0,
                     total_tokens: 1
                   },
                   file: nil
                 )
      end)

    assert log =~ "Failed to append token usage ledger record"
  end

  defp append!(ledger_file, issue_identifier, session_id, input_tokens, output_tokens, total_tokens) do
    TokenUsageLedger.append_observation(
      %{
        observed_at: "2026-04-20T10:00:00Z",
        final: false,
        issue_id: "issue-#{issue_identifier}",
        issue_identifier: issue_identifier,
        session_id: session_id,
        workspace_path: "/tmp/#{issue_identifier}",
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: total_tokens
      },
      file: ledger_file
    )
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
