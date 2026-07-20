defmodule SymphonyElixir.Asana.LiveE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Asana.Client, as: AsanaClient

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  @api_url "https://app.asana.com/api/1.0"
  @result_file "LIVE_ASANA_E2E_RESULT.txt"
  @task_fields "gid,name,notes,completed,resource_subtype,memberships.project.gid,memberships.section.gid,memberships.section.name,permalink_url,created_at,modified_at"
  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_ASANA_LIVE_E2E") != "1",
                          do: "set SYMPHONY_RUN_ASANA_LIVE_E2E=1 to enable the real Asana/Codex end-to-end test"
                        )

  @tag skip: @live_e2e_skip_reason
  test "creates a real Asana project and completes a task through asana_api" do
    workspace_gid = required_env!("SYMPHONY_LIVE_ASANA_WORKSPACE_GID")
    token = required_env!("ASANA_PAT")
    run_id = "symphony-asana-live-e2e-#{System.unique_integer([:positive])}"
    project_name = "Symphony Asana live e2e #{run_id}"
    active_name = "Symphony E2E Active #{run_id}"
    done_name = "Symphony E2E Done #{run_id}"
    test_root = Path.join(System.tmp_dir!(), run_id)
    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    workspace_root = Path.join(test_root, "workspaces")
    codex_home = isolated_codex_home!(test_root)
    original_workflow_path = Workflow.workflow_file_path()
    runtime_pid = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    File.mkdir_p!(workflow_root)

    team_gid = optional_env("SYMPHONY_LIVE_ASANA_TEAM_GID")
    project = create_project!(workspace_gid, team_gid, token, project_name)
    project_gid = project["gid"]

    try do
      active_section = create_section!(project_gid, token, active_name)
      done_section = create_section!(project_gid, token, done_name)
      task = create_task!(project_gid, token, "Symphony Asana live e2e task #{run_id}")
      task_gid = task["gid"]

      try do
        assert :ok = add_task_to_section(active_section["gid"], task_gid, token)

        task_payload = get_task!(task_gid, token)
        expected_comment = expected_comment("ASANA-#{task_gid}", run_id)

        assert %Issue{} =
                 issue =
                 AsanaClient.normalize_issue_for_test(
                   task_payload,
                   tracker_settings(project_gid, active_name, done_name)
                 )

        stop_agent_runtime_if_running(runtime_pid)
        Workflow.set_workflow_file_path(workflow_file)

        write_workflow!(
          workflow_file,
          project_gid,
          active_name,
          done_name,
          workspace_root,
          codex_home,
          live_prompt(project_gid, done_section["gid"], expected_comment)
        )

        assert %Issue{id: state_issue_id} = wait_for_active_state_issue!(issue.id, active_name)
        assert state_issue_id == issue.id

        assert {:ok, [%Issue{id: issue_id, identifier: identifier}]} =
                 Tracker.fetch_issues_by_ids([issue.id])

        assert issue_id == issue.id
        assert identifier == issue.identifier

        assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

        runtime_info = receive_runtime_info!(issue.id)
        tool_calls = completed_asana_tool_calls(issue.id)

        assert File.read!(Path.join(runtime_info.workspace_path, @result_file)) ==
                 expected_result(issue.identifier, project_gid)

        final_task = get_task!(task_gid, token)
        assert final_task["completed"] == true
        assert task_in_section?(final_task, project_gid, done_section["gid"])

        assert stories!(task_gid, token)
               |> Enum.any?(&(&1["resource_subtype"] == "comment_added" and &1["text"] == expected_comment))

        task_path = "/tasks/#{task_gid}"
        stories_path = task_path <> "/stories"
        move_path = "/sections/#{done_section["gid"]}/addTask"

        assert_tool_call_count!(tool_calls, "GET", task_path, 2)
        assert_tool_call_count!(tool_calls, "GET", stories_path, 2)
        assert_tool_call!(tool_calls, "POST", stories_path, %{"data" => %{"text" => expected_comment}})
        assert_tool_call!(tool_calls, "POST", move_path, %{"data" => %{"task" => task_gid}})
        assert_tool_call!(tool_calls, "PUT", task_path, %{"data" => %{"completed" => true}})
      after
        task_cleanup_result = delete_task(task_gid, token)
        task_readback = get_resource("/tasks/#{task_gid}", token)
        assert :ok = task_cleanup_result
        assert :not_found = task_readback
      end
    after
      cleanup_result = delete_project(project_gid, token)
      project_readback = get_resource("/projects/#{project_gid}", token)
      Workflow.set_workflow_file_path(original_workflow_path)
      restart_agent_runtime_if_needed(runtime_pid)
      File.rm_rf(test_root)
      assert :ok = cleanup_result
      assert :not_found = project_readback
    end
  end

  defp tracker_settings(project_gid, active_name, done_name) do
    %{
      kind: "asana",
      provider: %{"project_gid" => project_gid, "api_key" => "test-token"},
      active_states: [active_name],
      terminal_states: [done_name]
    }
  end

  defp write_workflow!(path, project_gid, active_name, done_name, workspace_root, codex_home, prompt) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: asana
        provider:
          project_gid: #{Jason.encode!(project_gid)}
          api_key: "$ASANA_PAT"
        active_states: [#{Jason.encode!(active_name)}]
        terminal_states: [#{Jason.encode!(done_name)}]
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

  defp live_prompt(project_gid, done_section_gid, expected_comment) do
    task_path = "/tasks/{{ issue.id }}"
    stories_path = task_path <> "/stories"

    """
    You are running a real Symphony Asana end-to-end test.

    The current working directory is the workspace root.

    Step 1:
    Run exactly:

    ```sh
    if [ -n "${ASANA_PAT:-}" ]; then asana_pat_present=yes; else asana_pat_present=no; fi
    cat > #{@result_file} <<EOF
    identifier={{ issue.identifier }}
    project_gid=#{project_gid}
    asana_pat_present=$asana_pat_present
    EOF
    ```

    Then verify the file with `cat #{@result_file}`. The final line must be `asana_pat_present=no`.

    Step 2:
    You must use `asana_api` for every Asana operation. First GET both:
    - #{task_path}
    - #{stories_path}

    If the exact comment below is not already present, POST it once to #{stories_path} using `body: {"data": {"text": "..."}}` with the exact text below:
    #{expected_comment}

    Step 3:
    POST /sections/#{done_section_gid}/addTask using `body: {"data": {"task": "{{ issue.id }}"}}`.
    Then PUT #{task_path} using `body: {"data": {"completed": true}}`.

    Step 4:
    Use `asana_api` again to GET #{task_path} and #{stories_path}. Stop only after:
    1. #{@result_file} has the exact three lines above and says `asana_pat_present=no`
    2. the exact comment is present
    3. the task is completed and belongs to section #{done_section_gid}

    Do not ask for approval.
    """
  end

  defp expected_result(identifier, project_gid) do
    "identifier=#{identifier}\nproject_gid=#{project_gid}\nasana_pat_present=no\n"
  end

  defp expected_comment(identifier, run_id) do
    "Symphony Asana live e2e comment\nidentifier=#{identifier}\nrun_id=#{run_id}"
  end

  defp create_project!(workspace_gid, team_gid, token, name) do
    data = %{"name" => name, "workspace" => workspace_gid} |> maybe_put("team", team_gid)

    asana_data!(
      :post,
      "/projects",
      token,
      %{"data" => data}
    )
  end

  defp create_section!(project_gid, token, name) do
    asana_data!(
      :post,
      "/projects/#{project_gid}/sections",
      token,
      %{"data" => %{"name" => name}}
    )
  end

  defp create_task!(project_gid, token, name) do
    asana_data!(
      :post,
      "/tasks",
      token,
      %{"data" => %{"name" => name, "projects" => [project_gid]}}
    )
  end

  defp get_task!(task_gid, token) do
    asana_data!(:get, "/tasks/#{task_gid}", token, nil, %{"opt_fields" => @task_fields})
  end

  defp stories!(task_gid, token) do
    case asana_request!(
           :get,
           "/tasks/#{task_gid}/stories",
           token,
           nil,
           %{"opt_fields" => "resource_subtype,text", "limit" => 100}
         ).body do
      %{"data" => stories} when is_list(stories) -> stories
      _ -> flunk("Asana stories read returned an unexpected payload")
    end
  end

  defp add_task_to_section(section_gid, task_gid, token) do
    case asana_request(
           :post,
           "/sections/#{section_gid}/addTask",
           token,
           %{"data" => %{"task" => task_gid}}
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:asana_add_task_status, status}}
      {:error, reason} -> {:error, {:asana_add_task_request, reason}}
    end
  end

  defp delete_project(project_gid, token) do
    case asana_request(:delete, "/projects/#{project_gid}", token, nil) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status}} -> {:error, {:asana_cleanup_status, status}}
      {:error, reason} -> {:error, {:asana_cleanup_request, reason}}
    end
  end

  defp delete_task(task_gid, token) do
    case asana_request(:delete, "/tasks/#{task_gid}", token, nil) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status}} -> {:error, {:asana_task_cleanup_status, status}}
      {:error, reason} -> {:error, {:asana_task_cleanup_request, reason}}
    end
  end

  defp get_resource(path, token) do
    case asana_request(:get, path, token, nil) do
      {:ok, %{status: 404}} -> :not_found
      {:ok, %{status: status}} when status in 200..299 -> :found
      {:ok, %{status: status}} -> flunk("Asana cleanup read failed with HTTP #{status}")
      {:error, reason} -> flunk("Asana cleanup read failed before a response: #{inspect(reason)}")
    end
  end

  defp asana_data!(method, path, token, body, query \\ %{}) do
    case asana_request!(method, path, token, body, query).body do
      %{"data" => %{} = data} -> data
      _ -> flunk("Asana request returned an unexpected data payload")
    end
  end

  defp asana_request!(method, path, token, body, query) do
    case asana_request(method, path, token, body, query) do
      {:ok, %{status: status} = response} when status in 200..299 -> response
      {:ok, %{status: status}} -> flunk("Asana request failed with HTTP #{status}")
      {:error, reason} -> flunk("Asana request failed before a response: #{inspect(reason)}")
    end
  end

  defp asana_request(method, path, token, body, query \\ %{}) do
    request_opts = [
      method: method,
      url: @api_url <> path,
      headers: [
        {"Accept", "application/json"},
        {"Authorization", "Bearer #{token}"}
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

  defp task_in_section?(%{"memberships" => memberships}, project_gid, section_gid)
       when is_list(memberships) do
    Enum.any?(memberships, fn membership ->
      get_in(membership, ["project", "gid"]) == project_gid and
        get_in(membership, ["section", "gid"]) == section_gid
    end)
  end

  defp task_in_section?(_task, _project_gid, _section_gid), do: false

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

  defp completed_asana_tool_calls(issue_id, calls \\ []) do
    receive do
      {:codex_worker_update, ^issue_id, %{event: :tool_call_completed, payload: %{"params" => params}}} ->
        completed_asana_tool_calls(issue_id, [params | calls])

      {:codex_worker_update, ^issue_id, _message} ->
        completed_asana_tool_calls(issue_id, calls)
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

    assert found?, "expected completed asana_api #{method} #{path}"
  end

  defp assert_tool_call_count!(calls, method, path, expected_count) do
    count = Enum.count(calls, &tool_call_matches?(&1, method, path))
    assert count >= expected_count, "expected at least #{expected_count} completed asana_api #{method} #{path} calls"
  end

  defp tool_call_matches?(params, method, path) do
    arguments = Map.get(params, "arguments", %{})
    tool_name = Map.get(params, "name") || Map.get(params, "tool")
    called_method = Map.get(arguments, "method")
    called_path = Map.get(arguments, "path")

    tool_name == "asana_api" and is_binary(called_method) and
      String.upcase(String.trim(called_method)) == method and
      is_binary(called_path) and String.trim(called_path) == path
  end

  defp wait_for_active_state_issue!(issue_id, state, attempts \\ 20)

  defp wait_for_active_state_issue!(issue_id, state, attempts) when attempts > 0 do
    case Tracker.fetch_issues_by_states([state]) do
      {:ok, issues} ->
        case Enum.find(issues, &(&1.id == issue_id)) do
          %Issue{} = issue ->
            issue

          nil ->
            Process.sleep(500)
            wait_for_active_state_issue!(issue_id, state, attempts - 1)
        end

      {:error, reason} ->
        flunk("Asana state read failed: #{inspect(reason)}")
    end
  end

  defp wait_for_active_state_issue!(_issue_id, _state, 0) do
    flunk("new Asana task did not appear in the active-state adapter read")
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
      flunk("live Asana e2e requires Codex auth")
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
      _ -> flunk("live Asana e2e requires #{name}")
    end
  end

  defp optional_env(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp shell_escape(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
