defmodule SymphonyElixir.Asana.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Asana.Adapter, as: AsanaAdapter
  alias SymphonyElixir.Asana.AgentTool, as: AsanaAgentTool
  alias SymphonyElixir.Asana.Client, as: AsanaClient

  defmodule FakeAsanaClient do
    def fetch_issues_by_states(states) do
      send(self(), {:asana_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:asana_ids_called, ids})
      {:ok, ids}
    end
  end

  setup do
    asana_client_module = Application.get_env(:symphony_elixir, :asana_client_module)

    on_exit(fn ->
      if is_nil(asana_client_module) do
        Application.delete_env(:symphony_elixir, :asana_client_module)
      else
        Application.put_env(:symphony_elixir, :asana_client_module, asana_client_module)
      end
    end)

    :ok
  end

  test "adapter validates Asana config, delegates reads, and advertises asana_api" do
    settings = tracker_settings()

    assert :ok = AsanaAdapter.validate_config(settings)

    assert {:error, :missing_asana_active_states} =
             AsanaAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_asana_terminal_states} =
             AsanaAdapter.validate_config(%{settings | terminal_states: nil})

    assert :ok = AsanaAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :invalid_asana_states} =
             AsanaAdapter.validate_config(%{settings | active_states: [""]})

    assert {:error, :invalid_asana_states} =
             AsanaAdapter.validate_config(%{settings | terminal_states: [42]})

    Application.put_env(:symphony_elixir, :asana_client_module, FakeAsanaClient)

    assert {:ok, ["Todo"]} = AsanaAdapter.fetch_issues_by_states(["Todo"])
    assert_receive {:asana_states_called, ["Todo"]}

    assert {:ok, ["42"]} = AsanaAdapter.fetch_issues_by_ids(["42"])
    assert_receive {:asana_ids_called, ["42"]}

    assert [%{"name" => "asana_api"}] = AsanaAdapter.agent_tool_specs()

    assert AsanaAdapter.execute_agent_tool(
             "asana_api",
             %{"method" => "GET", "path" => "/users/me"},
             asana_client: fn _method, _path, _query, _body, _opts ->
               {:ok, %{status: 200, body: %{"data" => %{"gid" => "me"}}}}
             end
           )["success"]
  end

  test "client validates project settings and declares token environments" do
    assert :ok = AsanaClient.validate_settings(tracker_settings())

    assert {:error, :missing_asana_project_gid} =
             AsanaClient.validate_settings(tracker_settings(%{"project_gid" => 123}))

    assert {:error, :missing_asana_api_key} =
             AsanaClient.validate_settings(tracker_settings(%{"api_key" => 123}))

    assert {:error, :invalid_asana_endpoint} =
             AsanaClient.validate_settings(tracker_settings(%{"endpoint" => "not a url"}))

    assert {:error, :invalid_asana_endpoint} =
             AsanaClient.validate_settings(tracker_settings(%{"endpoint" => "http://app.asana.com/api/1.0"}))

    assert AsanaClient.secret_environment_names(tracker_settings(%{"api_key" => "$SYMPHONY_ASANA_PAT"})) == ["ASANA_PAT", "SYMPHONY_ASANA_PAT"]

    assert {:ok, []} =
             AsanaClient.fetch_issues_by_states_for_test(
               ["Todo"],
               tracker_settings(%{"project_gid" => " project-1 ", "api_key" => " token "}),
               fn "GET", "/projects/project-1/tasks", _query, nil, settings ->
                 assert settings.project_gid == "project-1"
                 assert settings.api_key == "token"
                 {:ok, %{status: 200, body: %{"data" => [], "next_page" => nil}}}
               end
             )
  end

  test "client normalizes Asana tasks without dropping provider details" do
    task = AsanaClient.normalize_issue_for_test(raw_task("42"), tracker_settings())

    assert task.id == "42"
    assert task.identifier == "ASANA-42"

    assert task.native_ref == %{
             "task_gid" => "42",
             "project_gid" => "project-1",
             "section_gid" => "section-todo"
           }

    assert task.title == "Task 42"
    assert task.description == "Notes 42"
    assert task.state == "Todo"
    assert task.url == "https://app.asana.test/0/project-1/42"
    assert task.assignee_id == "assignee-1"
    assert task.labels == ["bug", "platform"]
    assert task.blocked_by == []
    assert task.dispatchable
    assert %DateTime{} = task.created_at
    assert %DateTime{} = task.updated_at

    refute AsanaClient.normalize_issue_for_test(
             Map.put(raw_task("43"), "completed", true),
             tracker_settings()
           ).dispatchable

    assert AsanaClient.normalize_issue_for_test(
             Map.put(raw_task("44"), "resource_subtype", "milestone"),
             tracker_settings()
           ).dispatchable

    refute AsanaClient.normalize_issue_for_test(
             Map.put(raw_task("46"), "resource_subtype", "section"),
             tracker_settings()
           ).dispatchable

    assert AsanaClient.normalize_issue_for_test(
             Map.put(raw_task("45"), "memberships", []),
             tracker_settings()
           ) == nil
  end

  test "client pages state reads, filters requested sections, and drops malformed records" do
    first_page = [raw_task("1"), raw_task("2"), Map.put(raw_task("3"), "name", "")]
    second_page = [task_in_section("4", "Done", "section-done")]

    request_fun = fn "GET", "/projects/project-1/tasks", query, nil, settings ->
      send(self(), {:asana_page, query, settings})

      body =
        case query["offset"] do
          nil -> %{"data" => first_page, "next_page" => %{"offset" => "next-token"}}
          "next-token" -> %{"data" => second_page, "next_page" => nil}
        end

      {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 AsanaClient.fetch_issues_by_states_for_test(
                   [" todo "],
                   tracker_settings(),
                   request_fun
                 )

        assert Enum.map(issues, & &1.id) == ["1", "2"]
      end)

    assert log =~ "Dropping malformed Asana task records count=1"

    assert_receive {:asana_page, %{"limit" => 100, "opt_fields" => opt_fields}, %{project_gid: "project-1"}}

    assert opt_fields =~ "memberships.section.name"
    assert_receive {:asana_page, %{"offset" => "next-token"}, %{project_gid: "project-1"}}

    assert {:ok, []} =
             AsanaClient.fetch_issues_by_states_for_test(
               [],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 flunk("empty Asana states should not make an HTTP request")
               end
             )
  end

  test "client refreshes IDs in order, omits 404s and out-of-project tasks, and rejects malformed refreshes" do
    request_fun = fn "GET", path, %{"opt_fields" => _fields}, nil, _settings ->
      send(self(), {:asana_id_path, path})

      case path do
        "/tasks/2" -> {:ok, %{status: 200, body: %{"data" => raw_task("2")}}}
        "/tasks/1" -> {:ok, %{status: 200, body: %{"data" => raw_task("1")}}}
        "/tasks/404" -> {:ok, %{status: 404, body: %{"errors" => []}}}
        "/tasks/out" -> {:ok, %{status: 200, body: %{"data" => out_of_project_task("out")}}}
      end
    end

    assert {:ok, issues} =
             AsanaClient.fetch_issues_by_ids_for_test(
               ["2", "1", "404", "out", "2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["2", "1"]
    assert_receive {:asana_id_path, "/tasks/2"}
    assert_receive {:asana_id_path, "/tasks/1"}
    assert_receive {:asana_id_path, "/tasks/404"}
    assert_receive {:asana_id_path, "/tasks/out"}
    refute_receive {:asana_id_path, "/tasks/2"}

    assert {:error, :asana_unknown_payload} =
             AsanaClient.fetch_issues_by_ids_for_test(
               ["bad"],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 {:ok, %{status: 200, body: %{"data" => Map.put(raw_task("bad"), "name", "")}}}
               end
             )

    assert {:ok, []} =
             AsanaClient.fetch_issues_by_ids_for_test(
               [],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 flunk("empty Asana IDs should not make an HTTP request")
               end
             )
  end

  test "asana_api preserves REST status and body while rejecting unsafe arguments" do
    test_pid = self()
    tracker_settings = tracker_settings()

    response =
      AsanaAgentTool.execute(
        "asana_api",
        %{
          "method" => "post",
          "path" => " /tasks/42/stories ",
          "query" => %{"opt_fields" => "gid"},
          "body" => %{"data" => %{"text" => "hello"}}
        },
        tracker_settings: tracker_settings,
        asana_client: fn method, path, query, body, opts ->
          send(test_pid, {:asana_tool_called, method, path, query, body, opts})
          {:ok, %{status: 201, body: %{"data" => %{"gid" => "story-1"}}}}
        end
      )

    assert_received {:asana_tool_called, "POST", "/tasks/42/stories", query, body, opts}
    assert query == %{"opt_fields" => "gid"}
    assert body == %{"data" => %{"text" => "hello"}}
    assert opts == [tracker_settings: tracker_settings]

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"data" => %{"gid" => "story-1"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    failure =
      AsanaAgentTool.execute(
        "asana_api",
        %{"method" => "GET", "path" => "/tasks/404"},
        asana_client: fn _method, _path, _query, _body, _opts ->
          {:ok, %{status: 404, body: %{"errors" => []}}}
        end
      )

    assert failure["success"] == false
    assert Jason.decode!(failure["output"]) == %{"status" => 404, "body" => %{"errors" => []}}

    Enum.each(
      [
        %{"method" => "GET", "path" => "https://app.asana.com/api/1.0/users/me"},
        %{"method" => "PATCH", "path" => "/users/me"},
        %{"method" => "GET", "path" => "/users/me", "query" => false},
        %{"path" => "/users/me"}
      ],
      fn arguments ->
        invalid =
          AsanaAgentTool.execute(
            "asana_api",
            arguments,
            asana_client: fn _method, _path, _query, _body, _opts ->
              flunk("invalid asana_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )
  end

  test "asana_api reports unsupported tools, malformed calls, and client failures" do
    unsupported = AsanaAgentTool.execute("not_asana_api", %{}, [])
    assert unsupported["success"] == false
    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["asana_api"]

    Enum.each(
      ["not-an-object", %{"method" => "GET", "path" => 123}],
      fn arguments ->
        invalid =
          AsanaAgentTool.execute(
            "asana_api",
            arguments,
            asana_client: fn _method, _path, _query, _body, _opts ->
              flunk("malformed asana_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )

    malformed_response =
      AsanaAgentTool.execute(
        "asana_api",
        %{"method" => "GET", "path" => "/users/me"},
        asana_client: fn _method, _path, _query, _body, _opts ->
          {:ok, %{status: "not-an-integer", body: %{}}}
        end
      )

    assert malformed_response["success"] == false

    Enum.each(
      [:missing_asana_api_key, {:asana_api_request, :timeout}, :unexpected_failure],
      fn reason ->
        failure =
          AsanaAgentTool.execute(
            "asana_api",
            %{"method" => "GET", "path" => "/users/me"},
            asana_client: fn _method, _path, _query, _body, _opts ->
              {:error, reason}
            end
          )

        assert failure["success"] == false
        assert %{"error" => %{"message" => message}} = Jason.decode!(failure["output"])
        assert is_binary(message)
      end
    )

    non_json_body =
      AsanaAgentTool.execute(
        "asana_api",
        %{"method" => "GET", "path" => "/users/me"},
        asana_client: fn _method, _path, _query, _body, _opts ->
          {:ok, %{status: 200, body: self()}}
        end
      )

    assert non_json_body["success"]
    assert non_json_body["output"] =~ "#PID"
  end

  test "tracker binds Asana tools and token env names from provider config" do
    token_env = "SYMPHONY_ASANA_PAT_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_asana_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == AsanaAdapter
    assert binding.secret_environment_names == ["ASANA_PAT", token_env]
    assert [%{"name" => "asana_api"}] = binding.tool_specs
    assert :ok = Config.validate!()
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "asana",
      provider:
        Map.merge(
          %{
            "project_gid" => "project-1",
            "api_key" => "test-token"
          },
          provider_overrides
        ),
      active_states: ["Todo"],
      terminal_states: ["Done"]
    }
  end

  defp raw_task(gid), do: task_in_section(gid, "Todo", "section-todo")

  defp task_in_section(gid, section_name, section_gid) do
    %{
      "gid" => gid,
      "name" => "Task #{gid}",
      "notes" => " Notes #{gid} ",
      "completed" => false,
      "resource_subtype" => "default_task",
      "assignee" => %{"gid" => "assignee-1"},
      "tags" => [%{"name" => " Bug "}, %{"name" => "bug"}, %{"name" => "Platform"}],
      "memberships" => [
        %{
          "project" => %{"gid" => "project-1"},
          "section" => %{"gid" => section_gid, "name" => section_name}
        }
      ],
      "permalink_url" => "https://app.asana.test/0/project-1/#{gid}",
      "created_at" => "2026-01-01T00:00:00Z",
      "modified_at" => "2026-01-02T00:00:00Z"
    }
  end

  defp out_of_project_task(gid) do
    put_in(raw_task(gid), ["memberships", Access.at(0), "project", "gid"], "other-project")
  end

  defp write_asana_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: asana
        provider:
          project_gid: "project-1"
          api_key: #{Jason.encode!(token)}
        active_states: ["Todo"]
        terminal_states: ["Done"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
