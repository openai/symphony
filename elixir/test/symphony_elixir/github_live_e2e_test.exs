defmodule SymphonyElixir.GitHub.LiveE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client, as: GitHubClient

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  @api_url "https://api.github.com"
  @api_version "2022-11-28"
  @result_file "LIVE_GITHUB_E2E_RESULT.txt"
  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_GITHUB_LIVE_E2E") != "1",
                          do: "set SYMPHONY_RUN_GITHUB_LIVE_E2E=1 to enable the real GitHub/Codex end-to-end test"
                        )

  @tag skip: @live_e2e_skip_reason
  test "creates a real GitHub issue and closes it through github_api" do
    repo = required_env!("SYMPHONY_LIVE_GITHUB_REPO")
    token = required_env!("GITHUB_TOKEN")
    run_id = "symphony-github-live-e2e-#{System.unique_integer([:positive])}"
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
        repo,
        token,
        "Symphony GitHub live e2e #{run_id}",
        "Disposable issue created by the Symphony GitHub live E2E test."
      )

    issue_number = Integer.to_string(issue_payload["number"])
    expected_comment = expected_comment("GH-#{issue_number}", run_id)

    try do
      assert %Issue{} = issue = GitHubClient.normalize_issue_for_test(issue_payload, repo)
      stop_agent_runtime_if_running(runtime_pid)
      Workflow.set_workflow_file_path(workflow_file)

      write_workflow!(
        workflow_file,
        repo,
        workspace_root,
        codex_home,
        live_prompt(repo, expected_comment)
      )

      assert %Issue{id: state_issue_id} = wait_for_open_state_issue!(issue.id)
      assert state_issue_id == issue.id

      assert {:ok, [%Issue{id: issue_id, identifier: identifier}]} =
               Tracker.fetch_issues_by_ids([issue.id])

      assert issue_id == issue.id
      assert identifier == issue.identifier

      assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

      runtime_info = receive_runtime_info!(issue.id)
      tool_calls = completed_github_tool_calls(issue.id)

      assert File.read!(Path.join(runtime_info.workspace_path, @result_file)) ==
               expected_result(issue.identifier, repo)

      assert %{"state" => "closed"} = get_issue!(repo, token, issue.id)

      assert comments!(repo, token, issue.id)
             |> Enum.any?(&(&1["body"] == expected_comment))

      issue_path = "/repos/#{encoded_repo(repo)}/issues/#{issue.id}"
      comments_path = issue_path <> "/comments"

      assert_tool_call_count!(tool_calls, "GET", issue_path, 2)
      assert_tool_call_count!(tool_calls, "GET", comments_path, 2)
      assert_tool_call!(tool_calls, "POST", comments_path, %{"body" => expected_comment})
      assert_tool_call!(tool_calls, "PATCH", issue_path, %{"state" => "closed"})
    after
      close_result = close_issue(repo, token, issue_number)
      Workflow.set_workflow_file_path(original_workflow_path)
      restart_agent_runtime_if_needed(runtime_pid)
      File.rm_rf(test_root)
      assert :ok = close_result
    end
  end

  defp write_workflow!(path, repo, workspace_root, codex_home, prompt) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: github
        provider:
          repo: #{Jason.encode!(repo)}
          token: "$GITHUB_TOKEN"
        active_states: ["open"]
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

  defp live_prompt(repo, expected_comment) do
    issue_path = "/repos/#{encoded_repo(repo)}/issues/{{ issue.id }}"
    comments_path = issue_path <> "/comments"

    """
    You are running a real Symphony GitHub end-to-end test.

    The current working directory is the workspace root.

    Step 1:
    Run exactly:

    ```sh
    cat > #{@result_file} <<EOF
    identifier={{ issue.identifier }}
    repo=#{repo}
    EOF
    ```

    Then verify the file with `cat #{@result_file}`.

    Step 2:
    You must use `github_api` for every GitHub operation. First GET both:
    - #{issue_path}
    - #{comments_path}

    If the exact comment below is not already present, POST it once to #{comments_path}:
    #{expected_comment}

    Use a JSON body with a single `body` field containing that exact multiline string.

    Step 3:
    PATCH #{issue_path} with {"state":"closed"}.

    Step 4:
    Use `github_api` again to GET #{issue_path} and #{comments_path}. Stop only after:
    1. #{@result_file} has the exact three lines above
    2. the exact comment is present
    3. the GitHub issue state is `closed`

    Do not ask for approval.
    """
  end

  defp expected_result(identifier, repo) do
    "identifier=#{identifier}\nrepo=#{repo}\n"
  end

  defp expected_comment(identifier, run_id) do
    "Symphony GitHub live e2e comment\nidentifier=#{identifier}\nrun_id=#{run_id}"
  end

  defp create_issue!(repo, token, title, body) do
    response =
      github_request!(
        :post,
        "/repos/#{encoded_repo(repo)}/issues",
        token,
        %{"title" => title, "body" => body}
      )

    case response.body do
      %{"number" => number} = issue when is_integer(number) -> issue
      _ -> flunk("GitHub issue create returned an unexpected payload")
    end
  end

  defp get_issue!(repo, token, issue_id) do
    response = github_request!(:get, "/repos/#{encoded_repo(repo)}/issues/#{issue_id}", token)

    case response.body do
      %{} = issue -> issue
      _ -> flunk("GitHub issue read returned an unexpected payload")
    end
  end

  defp comments!(repo, token, issue_id) do
    response =
      github_request!(
        :get,
        "/repos/#{encoded_repo(repo)}/issues/#{issue_id}/comments",
        token,
        nil,
        %{"per_page" => 100}
      )

    case response.body do
      comments when is_list(comments) -> comments
      _ -> flunk("GitHub issue comments read returned an unexpected payload")
    end
  end

  defp close_issue(repo, token, issue_id) do
    case github_request(
           :patch,
           "/repos/#{encoded_repo(repo)}/issues/#{issue_id}",
           token,
           %{"state" => "closed"}
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:github_cleanup_status, status}}
      {:error, reason} -> {:error, {:github_cleanup_request, reason}}
    end
  end

  defp github_request!(method, path, token, body \\ nil, params \\ %{}) do
    case github_request(method, path, token, body, params) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        response

      {:ok, %{status: status}} ->
        flunk("GitHub request failed with HTTP #{status}")

      {:error, reason} ->
        flunk("GitHub request failed before a response: #{inspect(reason)}")
    end
  end

  defp github_request(method, path, token, body, params \\ %{}) do
    request_opts = [
      method: method,
      url: @api_url <> path,
      headers: [
        {"Accept", "application/vnd.github+json"},
        {"Authorization", "Bearer #{token}"},
        {"X-GitHub-Api-Version", @api_version},
        {"User-Agent", "symphony-live-e2e"}
      ],
      params: params,
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

  defp completed_github_tool_calls(issue_id, calls \\ []) do
    receive do
      {:codex_worker_update, ^issue_id, %{event: :tool_call_completed, payload: %{"params" => params}}} ->
        completed_github_tool_calls(issue_id, [params | calls])

      {:codex_worker_update, ^issue_id, _message} ->
        completed_github_tool_calls(issue_id, calls)
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

    assert found?, "expected completed github_api #{method} #{path}"
  end

  defp assert_tool_call_count!(calls, method, path, expected_count) do
    count = Enum.count(calls, &tool_call_matches?(&1, method, path))
    assert count >= expected_count, "expected at least #{expected_count} completed github_api #{method} #{path} calls"
  end

  defp tool_call_matches?(params, method, path) do
    arguments = Map.get(params, "arguments", %{})
    tool_name = Map.get(params, "name") || Map.get(params, "tool")
    called_method = Map.get(arguments, "method")
    called_path = Map.get(arguments, "path")

    tool_name == "github_api" and is_binary(called_method) and
      String.upcase(String.trim(called_method)) == method and
      is_binary(called_path) and String.trim(called_path) == path
  end

  defp wait_for_open_state_issue!(issue_id, attempts \\ 20)

  defp wait_for_open_state_issue!(issue_id, attempts) when attempts > 0 do
    case Tracker.fetch_issues_by_states(["open"]) do
      {:ok, issues} ->
        case Enum.find(issues, &(&1.id == issue_id)) do
          %Issue{} = issue ->
            issue

          nil ->
            Process.sleep(500)
            wait_for_open_state_issue!(issue_id, attempts - 1)
        end

      {:error, reason} ->
        flunk("GitHub state read failed: #{inspect(reason)}")
    end
  end

  defp wait_for_open_state_issue!(_issue_id, 0) do
    flunk("new GitHub issue did not appear in the open-state adapter read")
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
      flunk("live GitHub e2e requires Codex auth")
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
      _ -> flunk("live GitHub e2e requires #{name}")
    end
  end

  defp encoded_repo(repo) do
    repo
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
