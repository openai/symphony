defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HttpServer.State, as: HttpServerState
  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)
    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert match?({:ok, _pid}, restart_result) or match?({:error, {:already_started, _pid}}, restart_result)
    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.tracker_kind() == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"
    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}
    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "http server serves html and json endpoints end-to-end" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    orchestrator_name = Module.concat(__MODULE__, :HttpOrchestrator)
    server_name = Module.concat(__MODULE__, :HttpServer)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    {:ok, server_pid} =
      HttpServer.start_link(
        name: server_name,
        host: "127.0.0.1",
        port: 0,
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 1_000
      )

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :normal)
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-HTTP",
      issue: %Issue{id: "issue-http", identifier: "MT-HTTP", state: "In Progress"},
      session_id: "thread-http",
      turn_count: 7,
      codex_app_server_pid: nil,
      last_codex_message: "rendered",
      last_codex_timestamp: nil,
      last_codex_event: :notification,
      codex_input_tokens: 4,
      codex_output_tokens: 8,
      codex_total_tokens: 12,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(orchestrator_pid, fn state ->
      %{
        state
        | running: %{"issue-http" => running_entry},
          retry_attempts: %{
            "issue-retry" => %{
              attempt: 2,
              due_at_ms: System.monotonic_time(:millisecond) + 2_000,
              identifier: "MT-RETRY",
              error: "boom"
            }
          }
      }
    end)

    port = wait_for_bound_port(server_name)
    assert HttpServer.bound_port(server_name) == port

    {status, headers, body} = http_request(port, "GET", "/")
    assert status == 200
    assert Map.fetch!(headers, "content-type") =~ "text/html"
    assert body =~ "Symphony Dashboard"

    {status, headers, body} = http_request(port, "GET", "/api/v1/state")
    assert status == 200
    assert Map.fetch!(headers, "content-type") =~ "application/json"

    assert %{
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [%{"issue_identifier" => "MT-HTTP", "last_message" => "rendered", "turn_count" => 7}],
             "retrying" => [%{"issue_identifier" => "MT-RETRY", "error" => "boom"}]
           } = Jason.decode!(body)

    :sys.replace_state(orchestrator_pid, fn state ->
      update_in(state.running["issue-http"].last_codex_message, fn _ -> %{message: "structured"} end)
    end)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/MT-HTTP")
    assert status == 200

    assert %{
             "issue_identifier" => "MT-HTTP",
             "status" => "running",
             "running" => %{"last_message" => "structured", "turn_count" => 7},
             "retry" => nil
           } = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/MT-RETRY")
    assert status == 200
    assert %{"status" => "retrying", "retry" => %{"attempt" => 2}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/MT-MISSING")
    assert status == 404
    assert %{"error" => %{"code" => "issue_not_found"}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "POST", "/api/v1/refresh", "")
    assert status == 202
    assert %{"coalesced" => false, "operations" => ["poll", "reconcile"], "queued" => true} = Jason.decode!(body)
  end

  test "http server escapes html-sensitive characters in rendered dashboard payload" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    orchestrator_name = Module.concat(__MODULE__, :EscapingHttpOrchestrator)
    server_name = Module.concat(__MODULE__, :EscapingHttpServer)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    {:ok, server_pid} =
      HttpServer.start_link(
        name: server_name,
        host: "127.0.0.1",
        port: 0,
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 1_000
      )

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :normal)
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-897",
      issue: %Issue{id: "issue-html", identifier: "MT-897", state: "In Progress"},
      session_id: "thread-html",
      turn_count: 7,
      codex_app_server_pid: nil,
      last_codex_message: "<script>window.xssed=1</script>",
      last_codex_timestamp: nil,
      last_codex_event: :notification,
      codex_input_tokens: 4,
      codex_output_tokens: 8,
      codex_total_tokens: 12,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(orchestrator_pid, fn state ->
      %{state | running: %{"issue-html" => running_entry}, retry_attempts: %{}}
    end)

    port = wait_for_bound_port(server_name)
    {status, _headers, body} = http_request(port, "GET", "/")
    assert status == 200
    refute String.contains?(body, "<script>window.xssed=1</script>")
    assert body =~ "&lt;script&gt;window.xssed=1&lt;/script&gt;"
  end

  test "http server returns method, parse, timeout, and unavailable errors" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    server_name = Module.concat(__MODULE__, :ErrorHttpServer)
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)

    {:ok, server_pid} =
      HttpServer.start_link(
        name: server_name,
        host: "127.0.0.1",
        port: 0,
        orchestrator: unavailable_orchestrator,
        snapshot_timeout_ms: 5
      )

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :normal)
    end)

    port = wait_for_bound_port(server_name)

    {status, _headers, body} = http_request(port, "POST", "/api/v1/state", "")
    assert status == 405
    assert %{"error" => %{"code" => "method_not_allowed"}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/refresh")
    assert status == 405
    assert %{"error" => %{"code" => "method_not_allowed"}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "POST", "/", "")
    assert status == 405
    assert %{"error" => %{"code" => "method_not_allowed"}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "POST", "/api/v1/MT-1", "")
    assert status == 405
    assert %{"error" => %{"code" => "method_not_allowed"}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "GET", "/unknown")
    assert status == 404
    assert %{"error" => %{"code" => "not_found"}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/state")
    assert status == 200
    assert %{"error" => %{"code" => "snapshot_unavailable"}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "POST", "/api/v1/refresh", "")
    assert status == 503
    assert %{"error" => %{"code" => "orchestrator_unavailable"}} = Jason.decode!(body)

    assert http_raw_request(port, "BROKEN\r\n\r\n") =~ "400 Bad Request"

    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, timeout_pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)

    timeout_server_name = Module.concat(__MODULE__, :TimeoutHttpServer)

    {:ok, timeout_server_pid} =
      HttpServer.start_link(
        name: timeout_server_name,
        host: "127.0.0.1",
        port: 0,
        orchestrator: timeout_orchestrator,
        snapshot_timeout_ms: 1
      )

    on_exit(fn ->
      if Process.alive?(timeout_server_pid), do: Process.exit(timeout_server_pid, :normal)
      if Process.alive?(timeout_pid), do: Process.exit(timeout_pid, :normal)
    end)

    timeout_port = wait_for_bound_port(timeout_server_name)
    {status, _headers, body} = http_request(timeout_port, "GET", "/api/v1/state")
    assert status == 200
    assert %{"error" => %{"code" => "snapshot_timeout"}} = Jason.decode!(body)
  end

  test "http server child spec, ignore branch, invalid host, and bound_port fallback behave as expected" do
    spec = HttpServer.child_spec(name: :child_spec_server, port: 0)
    assert spec.id == :child_spec_server
    assert spec.start == {HttpServer, :start_link, [[name: :child_spec_server, port: 0]]}

    Application.put_env(:symphony_elixir, :server_port_override, 0)

    {:ok, default_pid} = HttpServer.start_link()
    on_exit(fn -> if Process.alive?(default_pid), do: Process.exit(default_pid, :normal) end)

    {:ok, localhost_pid} = HttpServer.start_link(name: :localhost_server, host: "localhost", port: 0)

    on_exit(fn ->
      if Process.alive?(localhost_pid), do: Process.exit(localhost_pid, :normal)
    end)

    assert :ignore = HttpServer.start_link(name: :ignored_server, port: nil)
    assert is_integer(HttpServer.bound_port())
    assert is_integer(wait_for_bound_port(:localhost_server))
    assert HttpServer.bound_port(:ignored_server) == nil
    assert {:ok, {127, 0, 0, 1}} = HttpServer.parse_host_for_test({127, 0, 0, 1})
    assert {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} = HttpServer.parse_host_for_test({0, 0, 0, 0, 0, 0, 0, 1})
    assert {:stop, _reason} = HttpServer.init(name: :bad_host_server, host: "bad host", port: 0)
  end

  test "http server covers callback branches and synthetic snapshot payloads" do
    snapshot = %{
      running: [
        %{
          issue_id: "issue-both",
          identifier: "MT-BOTH",
          state: "In Progress",
          session_id: "thread-both",
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          started_at: nil,
          last_codex_timestamp: nil,
          last_codex_message: %{unexpected: true},
          last_codex_event: :notification
        }
      ],
      retrying: [
        %{
          issue_id: "issue-both",
          identifier: "MT-BOTH",
          attempt: 3,
          due_in_ms: nil,
          error: "still retrying"
        }
      ],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    orchestrator_name = Module.concat(__MODULE__, :StaticOrchestrator)
    server_name = Module.concat(__MODULE__, :StaticHttpServer)

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: true, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    {:ok, server_pid} =
      HttpServer.start_link(
        name: server_name,
        host: "127.0.0.1",
        port: 0,
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 50
      )

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :normal)
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    port = wait_for_bound_port(server_name)

    {status, _headers, body} =
      http_request(
        port,
        "GET",
        "/api/v1/state",
        nil,
        [{"broken-header", nil}]
      )

    assert status == 200
    assert %{"counts" => %{"running" => 1, "retrying" => 1}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/MT-BOTH")
    assert status == 200
    assert %{"status" => "running", "running" => %{"last_message" => nil}, "retry" => %{"due_at" => nil}} = Jason.decode!(body)

    {status, _headers, body} =
      http_request(
        port,
        "POST",
        "/api/v1/refresh",
        "",
        [{"content-length", "nope"}]
      )

    assert status == 202
    assert %{"coalesced" => true} = Jason.decode!(body)

    {status, _headers, body} =
      http_partial_request(port, "POST /api/v1/refresh HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 4\r\n\r\nbo", "dy")

    assert status == 202
    assert %{"queued" => true} = Jason.decode!(body)

    assert is_binary(
             http_partial_close_request(
               port,
               "POST /api/v1/refresh HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 4\r\n\r\nbo"
             )
           )

    oversized_header_response =
      http_raw_request(
        port,
        "GET /api/v1/state HTTP/1.1\r\nhost: 127.0.0.1\r\nx-overflow: #{String.duplicate("a", 9_000)}\r\n\r\n"
      )

    assert oversized_header_response =~ "413 Payload Too Large"
    assert oversized_header_response =~ "\"headers_too_large\""

    oversized_body_response =
      http_raw_request(
        port,
        "POST /api/v1/refresh HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 1048577\r\n\r\n"
      )

    assert oversized_body_response =~ "413 Payload Too Large"
    assert oversized_body_response =~ "\"body_too_large\""

    assert http_partial_close_request(
             port,
             "GET /api/v1/state HTTP/1.1\r\nhost: 127.0.0.1"
           ) == ""

    assert {:error, :bad_request} = HttpServer.parse_raw_request_for_test("GET /api/v1/state HTTP/1.1")
    assert {:error, :bad_request} = HttpServer.parse_raw_request_for_test("\r\n\r\n")

    unexpected_orchestrator = Module.concat(__MODULE__, :UnexpectedOrchestrator)
    unexpected_server = Module.concat(__MODULE__, :UnexpectedHttpServer)

    {:ok, unexpected_orchestrator_pid} =
      StaticOrchestrator.start_link(name: unexpected_orchestrator, snapshot: :unexpected)

    {:ok, unexpected_server_pid} =
      HttpServer.start_link(
        name: unexpected_server,
        host: "127.0.0.1",
        port: 0,
        orchestrator: unexpected_orchestrator,
        snapshot_timeout_ms: 50
      )

    on_exit(fn ->
      if Process.alive?(unexpected_server_pid), do: Process.exit(unexpected_server_pid, :normal)
      if Process.alive?(unexpected_orchestrator_pid), do: Process.exit(unexpected_orchestrator_pid, :normal)
    end)

    unexpected_port = wait_for_bound_port(unexpected_server)
    {status, _headers, body} = http_request(unexpected_port, "GET", "/api/v1/MT-BOTH")
    assert status == 404
    assert %{"error" => %{"code" => "issue_not_found"}} = Jason.decode!(body)

    {:ok, closed_socket} = :gen_tcp.listen(0, [:binary, {:active, false}])
    :gen_tcp.close(closed_socket)

    closed_state = %HttpServerState{
      listen_socket: closed_socket,
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 1
    }

    assert {:stop, :normal, ^closed_state} = HttpServer.handle_info(:accept, closed_state)

    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, listen_port} = :inet.port(listen_socket)
    acceptor = spawn(fn -> {:ok, _socket} = :gen_tcp.accept(listen_socket) end)
    {:ok, client_socket} = :gen_tcp.connect(~c"127.0.0.1", listen_port, [:binary, {:active, false}], 1_000)

    invalid_state = %HttpServerState{
      listen_socket: client_socket,
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 1
    }

    assert {:stop, :einval, ^invalid_state} = HttpServer.handle_info(:accept, invalid_state)
    :gen_tcp.close(client_socket)
    :gen_tcp.close(listen_socket)
    Process.exit(acceptor, :kill)

    {:ok, terminate_socket} = :gen_tcp.listen(0, [:binary, {:active, false}])

    assert :ok =
             HttpServer.terminate(
               :normal,
               %HttpServerState{
                 listen_socket: terminate_socket,
                 port: 0,
                 orchestrator: orchestrator_name,
                 snapshot_timeout_ms: 1
               }
             )

    assert :ok = HttpServer.terminate(:normal, :not_a_state)
  end

  defp wait_for_bound_port(server_name) do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port(server_name))
    end)

    HttpServer.bound_port(server_name)
  end

  defp http_request(port, method, path, body \\ nil, extra_headers \\ []) do
    request = build_http_request(method, path, body, extra_headers)

    response = http_raw_request(port, request)
    [header_block, response_body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(header_block, "\r\n")
    [_, status_code, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.reduce(header_lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> Map.put(acc, String.downcase(name), String.trim(value))
          _ -> acc
        end
      end)

    {String.to_integer(status_code), headers, response_body}
  end

  defp http_raw_request(port, request) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, request)
    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp http_partial_request(port, head, tail) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, head)
    Process.sleep(10)
    :ok = :gen_tcp.send(socket, tail)
    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    [header_block, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | _] = String.split(header_block, "\r\n")
    [_, status_code, _reason] = String.split(status_line, " ", parts: 3)
    {String.to_integer(status_code), %{}, body}
  end

  defp http_partial_close_request(port, request) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, request)
    :ok = :gen_tcp.shutdown(socket, :write)
    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp build_http_request(method, path, body, extra_headers) do
    headers =
      [
        {"host", "127.0.0.1"},
        {"connection", "close"}
      ] ++ extra_headers

    headers =
      if is_binary(body) and not Enum.any?(headers, fn {name, _value} -> name == "content-length" end) do
        headers ++ [{"content-length", Integer.to_string(byte_size(body))}]
      else
        headers
      end

    [
      "#{method} #{path} HTTP/1.1\r\n",
      Enum.map(headers, fn
        {name, nil} -> "#{name}\r\n"
        {name, value} -> "#{name}: #{value}\r\n"
      end),
      "\r\n",
      body || ""
    ]
    |> IO.iodata_to_binary()
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> acc
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
