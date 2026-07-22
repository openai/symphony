defmodule SymphonyElixir.Jira.LiveE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Client, as: JiraClient

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  @result_file "LIVE_JIRA_E2E_RESULT.txt"
  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_JIRA_LIVE_E2E") != "1",
                          do: "set SYMPHONY_RUN_JIRA_LIVE_E2E=1 to enable the real Jira/Codex end-to-end test"
                        )

  @tag skip: @live_e2e_skip_reason
  test "creates a real Jira issue and completes it through jira_rest" do
    base_url = required_env!("JIRA_BASE_URL")
    email = required_env!("JIRA_EMAIL")
    api_token = required_env!("JIRA_API_TOKEN")
    project_key = required_env!("SYMPHONY_LIVE_JIRA_PROJECT_KEY")
    run_id = "symphony-jira-live-e2e-#{System.unique_integer([:positive])}"
    test_root = Path.join(System.tmp_dir!(), run_id)
    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    workspace_root = Path.join(test_root, "workspaces")
    codex_home = isolated_codex_home!(test_root)
    original_workflow_path = Workflow.workflow_file_path()
    runtime_pid = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)
    issue_type_id = issue_type_id!(base_url, email, api_token, project_key)

    File.mkdir_p!(workflow_root)

    created_issue =
      create_issue!(
        base_url,
        email,
        api_token,
        project_key,
        issue_type_id,
        "Symphony Jira live e2e #{run_id}"
      )

    issue_id = created_issue["id"]
    issue_key = created_issue["key"]
    expected_comment = "Symphony Jira live e2e comment #{issue_key} #{run_id}"

    try do
      raw_issue = get_issue!(base_url, email, api_token, issue_id)
      initial_state = get_in(raw_issue, ["fields", "status", "name"])

      {terminal_state, terminal_transition_id} =
        terminal_transition!(base_url, email, api_token, issue_id)

      assert is_binary(initial_state) and initial_state != terminal_state

      settings =
        tracker_settings(base_url, email, api_token, project_key, initial_state, terminal_state)

      assert %Issue{} = issue = JiraClient.normalize_issue_for_test(raw_issue, settings)

      stop_agent_runtime_if_running(runtime_pid)
      Workflow.set_workflow_file_path(workflow_file)

      write_workflow!(
        workflow_file,
        project_key,
        initial_state,
        terminal_state,
        workspace_root,
        codex_home,
        live_prompt(issue_id, project_key, terminal_state, expected_comment)
      )

      assert %Issue{id: state_issue_id} = wait_for_state_issue!(issue.id, initial_state)
      assert state_issue_id == issue.id

      assert {:ok, [%Issue{id: refreshed_id, identifier: refreshed_identifier}]} =
               Tracker.fetch_issues_by_ids([issue.id])

      assert refreshed_id == issue.id
      assert refreshed_identifier == issue.identifier

      assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

      runtime_info = receive_runtime_info!(issue.id)
      tool_calls = completed_jira_tool_calls(issue.id)

      assert File.read!(Path.join(runtime_info.workspace_path, @result_file)) ==
               expected_result(issue.identifier, project_key)

      final_issue = get_issue!(base_url, email, api_token, issue.id, "status,comment")
      assert get_in(final_issue, ["fields", "status", "name"]) == terminal_state
      assert issue_comments(final_issue) |> Enum.any?(&(&1 == expected_comment))

      issue_path = "/rest/api/3/issue/#{issue.id}"
      comment_path = issue_path <> "/comment"
      transitions_path = issue_path <> "/transitions"

      assert_tool_call_count!(
        tool_calls,
        "GET",
        transitions_path,
        1
      )

      assert_tool_call_count!(tool_calls, "GET", issue_path, 2)
      assert_tool_call!(tool_calls, "POST", comment_path, %{"body" => comment_adf(expected_comment)})

      assert_tool_call!(
        tool_calls,
        "POST",
        transitions_path,
        %{"transition" => %{"id" => terminal_transition_id}}
      )
    after
      delete_result = delete_issue(base_url, email, api_token, issue_id)

      deleted_issue_result =
        jira_request(
          :get,
          base_url,
          email,
          api_token,
          "/rest/api/3/issue/#{issue_id}",
          %{}
        )

      Workflow.set_workflow_file_path(original_workflow_path)
      restart_agent_runtime_if_needed(runtime_pid)
      File.rm_rf(test_root)
      assert :ok = delete_result
      assert {:ok, %{status: 404}} = deleted_issue_result
    end
  end

  defp write_workflow!(
         path,
         project_key,
         active_state,
         terminal_state,
         workspace_root,
         codex_home,
         prompt
       ) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: jira
        provider:
          base_url: "$JIRA_BASE_URL"
          email: "$JIRA_EMAIL"
          api_token: "$JIRA_API_TOKEN"
          project_key: #{Jason.encode!(project_key)}
        active_states: [#{Jason.encode!(active_state)}]
        terminal_states: [#{Jason.encode!(terminal_state)}]
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

  defp live_prompt(issue_id, project_key, terminal_state, expected_comment) do
    issue_path = "/rest/api/3/issue/#{issue_id}"
    comment_path = issue_path <> "/comment"
    transitions_path = issue_path <> "/transitions"
    comment_body = %{"body" => comment_adf(expected_comment)} |> Jason.encode!()

    """
    You are running a real Symphony Jira end-to-end test.

    The current working directory is the workspace root.

    Step 1:
    Create #{@result_file} with exactly:
    identifier={{ issue.identifier }}
    project_key=#{project_key}

    Step 2:
    You must use jira_rest for every Jira operation. First GET:
    - #{transitions_path}?expand=transitions.fields
    - #{issue_path}?fields=status,comment

    If the exact comment below is not already present, POST it once to #{comment_path}:
    #{expected_comment}

    Use this exact JSON body:
    #{comment_body}

    Step 3:
    Choose the transition whose destination name is #{terminal_state}, then POST its id to #{transitions_path}
    with a body shaped as {"transition":{"id":"..."}}.

    Step 4:
    GET #{issue_path}?fields=status,comment again. Stop only after:
    1. #{@result_file} exists with the exact two lines above
    2. the exact comment is present
    3. the Jira status name is #{terminal_state}

    Do not ask for approval.
    """
  end

  defp expected_result(identifier, project_key) do
    "identifier=#{identifier}\nproject_key=#{project_key}\n"
  end

  defp tracker_settings(base_url, email, api_token, project_key, active_state, terminal_state) do
    %{
      kind: "jira",
      provider: %{
        "base_url" => base_url,
        "email" => email,
        "api_token" => api_token,
        "project_key" => project_key
      },
      active_states: [active_state],
      terminal_states: [terminal_state]
    }
  end

  defp issue_type_id!(base_url, email, api_token, project_key) do
    response =
      jira_request!(
        :get,
        base_url,
        email,
        api_token,
        "/rest/api/3/issue/createmeta/#{URI.encode(project_key, &URI.char_unreserved?/1)}/issuetypes",
        %{}
      )

    issue_type =
      response.body
      |> Map.get("issueTypes", [])
      |> Enum.find(&(Map.get(&1, "subtask") != true))

    case issue_type do
      %{"id" => id} when is_binary(id) -> id
      _ -> flunk("Jira live e2e could not find a non-subtask issue type")
    end
  end

  defp terminal_transition!(base_url, email, api_token, issue_id) do
    response =
      jira_request!(
        :get,
        base_url,
        email,
        api_token,
        "/rest/api/3/issue/#{issue_id}/transitions",
        %{}
      )

    transition =
      response.body
      |> Map.get("transitions", [])
      |> Enum.find(&(get_in(&1, ["to", "statusCategory", "key"]) == "done"))

    case transition do
      %{"id" => id, "to" => %{"name" => name}}
      when is_binary(id) and id != "" and is_binary(name) and name != "" ->
        {name, id}

      _ ->
        flunk("Jira live e2e could not find a terminal workflow transition")
    end
  end

  defp create_issue!(base_url, email, api_token, project_key, issue_type_id, title) do
    response =
      jira_request!(
        :post,
        base_url,
        email,
        api_token,
        "/rest/api/3/issue",
        %{},
        %{
          "fields" => %{
            "project" => %{"key" => project_key},
            "summary" => title,
            "description" => comment_adf(title),
            "issuetype" => %{"id" => issue_type_id}
          }
        }
      )

    case response.body do
      %{"id" => id, "key" => key} = issue when is_binary(id) and is_binary(key) -> issue
      _ -> flunk("Jira issue create returned an unexpected payload")
    end
  end

  defp get_issue!(base_url, email, api_token, issue_id, fields \\ "summary,description,status,labels,assignee,created,updated,project") do
    response =
      jira_request!(
        :get,
        base_url,
        email,
        api_token,
        "/rest/api/3/issue/#{issue_id}",
        %{"fields" => fields}
      )

    case response.body do
      %{} = issue -> issue
      _ -> flunk("Jira issue read returned an unexpected payload")
    end
  end

  defp issue_comments(%{"fields" => %{"comment" => %{"comments" => comments}}})
       when is_list(comments) do
    Enum.map(comments, &adf_text(&1["body"]))
  end

  defp issue_comments(_issue), do: []

  defp comment_adf(text) do
    %{
      "type" => "doc",
      "version" => 1,
      "content" => [
        %{
          "type" => "paragraph",
          "content" => [%{"type" => "text", "text" => text}]
        }
      ]
    }
  end

  defp adf_text(%{"text" => text}) when is_binary(text), do: text

  defp adf_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "", &adf_text/1)
  end

  defp adf_text(_value), do: ""

  defp delete_issue(base_url, email, api_token, issue_id) do
    case jira_request(
           :delete,
           base_url,
           email,
           api_token,
           "/rest/api/3/issue/#{issue_id}",
           %{"deleteSubtasks" => "true"}
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:jira_cleanup_status, status}}
      {:error, reason} -> {:error, {:jira_cleanup_request, reason}}
    end
  end

  defp jira_request!(method, base_url, email, api_token, path, query, body \\ nil) do
    case jira_request(method, base_url, email, api_token, path, query, body) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        response

      {:ok, %{status: status}} ->
        flunk("Jira request failed with HTTP #{status}")

      {:error, reason} ->
        flunk("Jira request failed before a response: #{inspect(reason)}")
    end
  end

  defp jira_request(method, base_url, email, api_token, path, query, body \\ nil) do
    request_opts = [
      method: method,
      url: String.trim_trailing(base_url, "/") <> path,
      headers: [
        {"Accept", "application/json"},
        {"Authorization", "Basic #{Base.encode64("#{email}:#{api_token}")}"}
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

  defp completed_jira_tool_calls(issue_id, calls \\ []) do
    receive do
      {:codex_worker_update, ^issue_id, %{event: :tool_call_completed, payload: %{"params" => params}}} ->
        completed_jira_tool_calls(issue_id, [params | calls])

      {:codex_worker_update, ^issue_id, _message} ->
        completed_jira_tool_calls(issue_id, calls)
    after
      0 ->
        Enum.reverse(calls)
    end
  end

  defp assert_tool_call!(calls, method, path, expected_body) do
    found? =
      Enum.any?(calls, fn params ->
        tool_call_matches?(params, method, path) and
          get_in(params, ["arguments", "body"]) == expected_body
      end)

    assert found?, "expected completed jira_rest #{method} #{path}"
  end

  defp assert_tool_call_count!(calls, method, path, expected_count) do
    count = Enum.count(calls, &tool_call_matches?(&1, method, path))
    assert count >= expected_count, "expected at least #{expected_count} completed jira_rest #{method} #{path} calls"
  end

  defp tool_call_matches?(params, method, path) do
    arguments = Map.get(params, "arguments", %{})
    tool_name = Map.get(params, "name") || Map.get(params, "tool")
    called_method = Map.get(arguments, "method")
    called_path = Map.get(arguments, "path")

    tool_name == "jira_rest" and is_binary(called_method) and
      String.upcase(String.trim(called_method)) == method and
      is_binary(called_path) and String.trim(called_path) == path
  end

  defp wait_for_state_issue!(issue_id, state, attempts \\ 20)

  defp wait_for_state_issue!(issue_id, state, attempts) when attempts > 0 do
    case Tracker.fetch_issues_by_states([state]) do
      {:ok, issues} ->
        case Enum.find(issues, &(&1.id == issue_id)) do
          %Issue{} = issue ->
            issue

          nil ->
            Process.sleep(500)
            wait_for_state_issue!(issue_id, state, attempts - 1)
        end

      {:error, reason} ->
        flunk("Jira state read failed: #{inspect(reason)}")
    end
  end

  defp wait_for_state_issue!(_issue_id, _state, 0) do
    flunk("new Jira issue did not appear in the adapter state read")
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
      flunk("live Jira e2e requires Codex auth")
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
      _ -> flunk("live Jira e2e requires #{name}")
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
