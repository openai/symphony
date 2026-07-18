defmodule SymphonyElixir.GitLab.LiveE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitLab.Client, as: GitLabClient

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  @api_url "https://gitlab.com/api/v4"
  @result_file "LIVE_GITLAB_E2E_RESULT.txt"
  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_GITLAB_LIVE_E2E") != "1",
                          do: "set SYMPHONY_RUN_GITLAB_LIVE_E2E=1 to enable the real GitLab/Codex end-to-end test"
                        )

  @tag skip: @live_e2e_skip_reason
  test "creates a real GitLab issue and closes it through gitlab_api" do
    project_id = required_env!("SYMPHONY_LIVE_GITLAB_PROJECT_ID")
    token = required_env!("GITLAB_PAT")
    run_id = "symphony-gitlab-live-e2e-#{System.unique_integer([:positive])}"
    test_root = Path.join(System.tmp_dir!(), run_id)
    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    workspace_root = Path.join(test_root, "workspaces")
    codex_home = isolated_codex_home!(test_root)
    original_workflow_path = Workflow.workflow_file_path()
    runtime_pid = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    File.mkdir_p!(workflow_root)

    issue_payload =
      create_issue!(
        project_id,
        token,
        "Symphony GitLab live e2e #{run_id}",
        "Disposable issue created by the Symphony GitLab live E2E test."
      )

    issue_iid = Integer.to_string(issue_payload["iid"])
    expected_comment = expected_comment("GL-#{issue_iid}", run_id)

    try do
      assert %Issue{} =
               issue =
               GitLabClient.normalize_issue_for_test(
                 issue_payload,
                 tracker_settings(project_id)
               )

      stop_agent_runtime_if_running(runtime_pid)
      Workflow.set_workflow_file_path(workflow_file)

      write_workflow!(
        workflow_file,
        project_id,
        workspace_root,
        codex_home,
        live_prompt(project_id, expected_comment)
      )

      assert %Issue{id: state_issue_id} = wait_for_open_state_issue!(issue.id)
      assert state_issue_id == issue.id

      assert {:ok, [%Issue{id: issue_id, identifier: identifier}]} =
               Tracker.fetch_issues_by_ids([issue.id])

      assert issue_id == issue.id
      assert identifier == issue.identifier

      assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

      runtime_info = receive_runtime_info!(issue.id)
      tool_calls = completed_gitlab_tool_calls(issue.id)

      assert File.read!(Path.join(runtime_info.workspace_path, @result_file)) ==
               expected_result(issue.identifier, project_id)

      assert %{"state" => "closed"} = get_issue!(project_id, token, issue.id)

      assert notes!(project_id, token, issue.id)
             |> Enum.any?(&(&1["body"] == expected_comment))

      issue_path = "/projects/#{project_id}/issues/#{issue.id}"
      notes_path = issue_path <> "/notes"

      assert_tool_call_count!(tool_calls, "GET", issue_path, 2)
      assert_tool_call_count!(tool_calls, "GET", notes_path, 2)
      assert_tool_call!(tool_calls, "POST", notes_path, %{"body" => expected_comment})
      assert_tool_call!(tool_calls, "PUT", issue_path, %{"state_event" => "close"})
    after
      close_result = close_issue(project_id, token, issue_iid)
      delete_result = delete_issue(project_id, token, issue_iid)
      Workflow.set_workflow_file_path(original_workflow_path)
      restart_agent_runtime_if_needed(runtime_pid)
      File.rm_rf(test_root)
      assert :ok = close_result
      assert :ok = delete_result
      assert :not_found = get_issue(project_id, token, issue_iid)
    end
  end

  defp tracker_settings(project_id) do
    %{
      kind: "gitlab",
      provider: %{"project_path" => project_id, "api_key" => "test-token"},
      active_states: ["opened"],
      terminal_states: ["closed"]
    }
  end

  defp write_workflow!(path, project_id, workspace_root, codex_home, prompt) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: gitlab
        provider:
          project_path: #{Jason.encode!(project_id)}
          api_key: "$GITLAB_PAT"
        active_states: ["opened"]
        terminal_states: ["closed"]
      workspace:
        root: #{Jason.encode!(workspace_root)}
      agent:
        max_turns: 3
      codex:
        command: #{Jason.encode!("env CODEX_HOME=#{shell_escape(codex_home)} codex app-server")}
        approval_policy: "never"
        read_timeout_ms: 60000
        turn_timeout_ms: 600000
        stall_timeout_ms: 600000
      observability:
        dashboard_enabled: false
      ---

      #{prompt}
      """
    )

    assert :ok = SymphonyElixir.WorkflowStore.force_reload()
  end

  defp live_prompt(project_id, expected_comment) do
    issue_path = "/projects/#{project_id}/issues/{{ issue.id }}"
    notes_path = issue_path <> "/notes"

    """
    You are running a real Symphony GitLab end-to-end test.

    The current working directory is the workspace root.

    Step 1:
    Run exactly:

    ```sh
    if [ -n "${GITLAB_PAT:-}" ]; then gitlab_pat_present=yes; else gitlab_pat_present=no; fi
    if [ -n "${GITLAB_ACCESS_TOKEN:-}" ]; then gitlab_access_token_present=yes; else gitlab_access_token_present=no; fi
    cat > #{@result_file} <<EOF
    identifier={{ issue.identifier }}
    project_id=#{project_id}
    gitlab_pat_present=$gitlab_pat_present
    gitlab_access_token_present=$gitlab_access_token_present
    EOF
    ```

    Then verify the file with `cat #{@result_file}`. Both secret-presence lines must end in `no`.

    Step 2:
    You must use `gitlab_api` for every GitLab operation. First GET both:
    - #{issue_path}
    - #{notes_path}

    If the exact comment below is not already present, POST it once to #{notes_path} with a JSON body containing a single `body` field:
    #{expected_comment}

    Step 3:
    PUT #{issue_path} with `{"state_event": "close"}`.

    Step 4:
    Use `gitlab_api` again to GET #{issue_path} and #{notes_path}. Stop only after:
    1. #{@result_file} has the exact four lines above and both secret-presence values are `no`
    2. the exact comment is present
    3. the GitLab issue state is `closed`

    Do not ask for approval.
    """
  end

  defp expected_result(identifier, project_id) do
    "identifier=#{identifier}\nproject_id=#{project_id}\ngitlab_pat_present=no\ngitlab_access_token_present=no\n"
  end

  defp expected_comment(identifier, run_id) do
    "Symphony GitLab live e2e comment\nidentifier=#{identifier}\nrun_id=#{run_id}"
  end

  defp create_issue!(project_id, token, title, description) do
    response =
      gitlab_request!(
        :post,
        "/projects/#{project_id}/issues",
        token,
        %{"title" => title, "description" => description}
      )

    case response.body do
      %{"iid" => iid} = issue when is_integer(iid) -> issue
      _ -> flunk("GitLab issue create returned an unexpected payload")
    end
  end

  defp get_issue!(project_id, token, issue_iid) do
    case get_issue(project_id, token, issue_iid) do
      %{} = issue -> issue
      :not_found -> flunk("GitLab issue read unexpectedly returned 404")
    end
  end

  defp get_issue(project_id, token, issue_iid) do
    case gitlab_request(:get, "/projects/#{project_id}/issues/#{issue_iid}", token, nil) do
      {:ok, %{status: status, body: %{} = issue}} when status in 200..299 -> issue
      {:ok, %{status: 404}} -> :not_found
      {:ok, %{status: status}} -> flunk("GitLab issue read failed with HTTP #{status}")
      {:error, reason} -> flunk("GitLab issue read failed before a response: #{inspect(reason)}")
    end
  end

  defp notes!(project_id, token, issue_iid) do
    response =
      gitlab_request!(
        :get,
        "/projects/#{project_id}/issues/#{issue_iid}/notes",
        token,
        nil,
        %{"per_page" => 100}
      )

    case response.body do
      notes when is_list(notes) -> notes
      _ -> flunk("GitLab issue notes read returned an unexpected payload")
    end
  end

  defp close_issue(project_id, token, issue_iid) do
    case gitlab_request(
           :put,
           "/projects/#{project_id}/issues/#{issue_iid}",
           token,
           %{"state_event" => "close"}
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status}} -> {:error, {:gitlab_cleanup_status, status}}
      {:error, reason} -> {:error, {:gitlab_cleanup_request, reason}}
    end
  end

  defp delete_issue(project_id, token, issue_iid) do
    case gitlab_request(:delete, "/projects/#{project_id}/issues/#{issue_iid}", token, nil) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status}} -> {:error, {:gitlab_delete_status, status}}
      {:error, reason} -> {:error, {:gitlab_delete_request, reason}}
    end
  end

  defp gitlab_request!(method, path, token, body, query \\ %{}) do
    case gitlab_request(method, path, token, body, query) do
      {:ok, %{status: status} = response} when status in 200..299 -> response
      {:ok, %{status: status}} -> flunk("GitLab request failed with HTTP #{status}")
      {:error, reason} -> flunk("GitLab request failed before a response: #{inspect(reason)}")
    end
  end

  defp gitlab_request(method, path, token, body, query \\ %{}) do
    request_opts = [
      method: method,
      url: @api_url <> path,
      headers: [
        {"Accept", "application/json"},
        {"PRIVATE-TOKEN", token}
      ],
      params: query,
      connect_options: [timeout: 30_000]
    ]

    request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

    case Req.request(request_opts) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp receive_runtime_info!(issue_id) do
    receive do
      {:worker_runtime_info, ^issue_id, %{workspace_path: workspace_path} = runtime_info}
      when is_binary(workspace_path) ->
        runtime_info

      {:codex_worker_update, ^issue_id, _message} ->
        receive_runtime_info!(issue_id)
    after
      5_000 ->
        flunk("timed out waiting for worker runtime info")
    end
  end

  defp completed_gitlab_tool_calls(issue_id, calls \\ []) do
    receive do
      {:codex_worker_update, ^issue_id, %{event: :tool_call_completed, payload: %{"params" => params}}} ->
        completed_gitlab_tool_calls(issue_id, [params | calls])

      {:codex_worker_update, ^issue_id, _message} ->
        completed_gitlab_tool_calls(issue_id, calls)
    after
      0 ->
        Enum.reverse(calls)
    end
  end

  defp assert_tool_call!(calls, method, path, expected_body) do
    found? =
      Enum.any?(calls, fn params ->
        tool_call_matches?(params, method, path) and
          (expected_body == :any or get_in(params, ["arguments", "body"]) == expected_body)
      end)

    assert found?, "expected completed gitlab_api #{method} #{path}"
  end

  defp assert_tool_call_count!(calls, method, path, expected_count) do
    count = Enum.count(calls, &tool_call_matches?(&1, method, path))
    assert count >= expected_count, "expected at least #{expected_count} completed gitlab_api #{method} #{path} calls"
  end

  defp tool_call_matches?(params, method, path) do
    arguments = Map.get(params, "arguments", %{})
    tool_name = Map.get(params, "name") || Map.get(params, "tool")
    called_method = Map.get(arguments, "method")
    called_path = Map.get(arguments, "path")

    tool_name == "gitlab_api" and is_binary(called_method) and
      String.upcase(String.trim(called_method)) == method and
      is_binary(called_path) and String.trim(called_path) == path
  end

  defp wait_for_open_state_issue!(issue_id, attempts \\ 20)

  defp wait_for_open_state_issue!(issue_id, attempts) when attempts > 0 do
    case Tracker.fetch_issues_by_states(["opened"]) do
      {:ok, issues} ->
        case Enum.find(issues, &(&1.id == issue_id)) do
          %Issue{} = issue ->
            issue

          nil ->
            Process.sleep(500)
            wait_for_open_state_issue!(issue_id, attempts - 1)
        end

      {:error, reason} ->
        flunk("GitLab state read failed: #{inspect(reason)}")
    end
  end

  defp wait_for_open_state_issue!(_issue_id, 0) do
    flunk("new GitLab issue did not appear in the open-state adapter read")
  end

  defp isolated_codex_home!(test_root) do
    codex_home = Path.join(test_root, "codex-home")
    auth_json_path = Path.join(codex_home, "auth.json")

    source_auth_json =
      Path.join(
        System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
        "auth.json"
      )

    unless File.regular?(source_auth_json) do
      flunk("live GitLab e2e requires Codex auth")
    end

    File.mkdir_p!(codex_home)
    File.cp!(source_auth_json, auth_json_path)
    File.chmod!(auth_json_path, 0o600)
    codex_home
  end

  defp stop_agent_runtime_if_running(runtime_pid) when is_pid(runtime_pid) do
    assert :ok =
             Supervisor.terminate_child(
               SymphonyElixir.Supervisor,
               SymphonyElixir.AgentRuntimeSupervisor
             )
  end

  defp stop_agent_runtime_if_running(_runtime_pid), do: :ok

  defp restart_agent_runtime_if_needed(runtime_pid) when is_pid(runtime_pid) do
    if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
      case Supervisor.restart_child(
             SymphonyElixir.Supervisor,
             SymphonyElixir.AgentRuntimeSupervisor
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp restart_agent_runtime_if_needed(_runtime_pid), do: :ok

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> flunk("live GitLab e2e requires #{name}")
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
