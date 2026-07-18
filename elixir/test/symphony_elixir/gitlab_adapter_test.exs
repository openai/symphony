defmodule SymphonyElixir.GitLab.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitLab.Adapter, as: GitLabAdapter
  alias SymphonyElixir.GitLab.AgentTool, as: GitLabAgentTool
  alias SymphonyElixir.GitLab.Client, as: GitLabClient

  defmodule FakeGitLabClient do
    def fetch_issues_by_states(states) do
      send(self(), {:gitlab_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:gitlab_ids_called, ids})
      {:ok, ids}
    end
  end

  setup do
    gitlab_client_module = Application.get_env(:symphony_elixir, :gitlab_client_module)

    on_exit(fn ->
      if is_nil(gitlab_client_module) do
        Application.delete_env(:symphony_elixir, :gitlab_client_module)
      else
        Application.put_env(:symphony_elixir, :gitlab_client_module, gitlab_client_module)
      end
    end)

    :ok
  end

  test "adapter validates GitLab config, delegates reads, and advertises gitlab_api" do
    settings = tracker_settings()

    assert :ok = GitLabAdapter.validate_config(settings)

    assert {:error, :missing_gitlab_active_states} =
             GitLabAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_gitlab_terminal_states} =
             GitLabAdapter.validate_config(%{settings | terminal_states: nil})

    assert :ok = GitLabAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :invalid_gitlab_states} =
             GitLabAdapter.validate_config(%{settings | active_states: ["Todo"]})

    assert {:error, :invalid_gitlab_states} =
             GitLabAdapter.validate_config(%{settings | active_states: [42]})

    assert {:error, :invalid_gitlab_states} =
             GitLabAdapter.validate_config(%{settings | active_states: ["closed"]})

    assert {:error, :invalid_gitlab_states} =
             GitLabAdapter.validate_config(%{settings | terminal_states: ["opened"]})

    Application.put_env(:symphony_elixir, :gitlab_client_module, FakeGitLabClient)

    assert {:ok, ["opened"]} = GitLabAdapter.fetch_issues_by_states(["opened"])
    assert_receive {:gitlab_states_called, ["opened"]}

    assert {:ok, ["42"]} = GitLabAdapter.fetch_issues_by_ids(["42"])
    assert_receive {:gitlab_ids_called, ["42"]}

    assert [%{"name" => "gitlab_api"}] = GitLabAdapter.agent_tool_specs()

    assert GitLabAdapter.execute_agent_tool(
             "gitlab_api",
             %{"method" => "GET", "path" => "/user"},
             gitlab_client: fn _method, _path, _query, _body, _opts ->
               {:ok, %{status: 200, body: %{"username" => "octocat"}}}
             end
           )["success"]
  end

  test "client validates project settings and declares token environments" do
    assert :ok = GitLabClient.validate_settings(tracker_settings())

    assert {:error, :missing_gitlab_project_path} =
             GitLabClient.validate_settings(tracker_settings(%{"project_path" => 123}))

    assert {:error, :invalid_gitlab_project_path} =
             GitLabClient.validate_settings(tracker_settings(%{"project_path" => "group / project"}))

    assert {:error, :missing_gitlab_api_key} =
             GitLabClient.validate_settings(tracker_settings(%{"api_key" => 123}))

    assert {:error, :invalid_gitlab_api_url} =
             GitLabClient.validate_settings(tracker_settings(%{"api_url" => "not a url"}))

    assert {:error, :invalid_gitlab_api_url} =
             GitLabClient.validate_settings(tracker_settings(%{"api_url" => "http://gitlab.com/api/v4"}))

    assert GitLabClient.secret_environment_names(tracker_settings(%{"api_key" => "$SYMPHONY_GITLAB_TOKEN"})) == ["GITLAB_PAT", "GITLAB_ACCESS_TOKEN", "SYMPHONY_GITLAB_TOKEN"]

    assert {:ok, []} =
             GitLabClient.fetch_issues_by_states_for_test(
               ["opened"],
               tracker_settings(%{"project_path" => " group/project ", "api_key" => " token "}),
               fn "GET", "/projects/group%2Fproject/issues", _query, nil, settings ->
                 assert settings.project_path == "group/project"
                 assert settings.api_key == "token"
                 {:ok, %{status: 200, body: []}}
               end
             )
  end

  test "client normalizes GitLab issues without dropping provider details" do
    issue = GitLabClient.normalize_issue_for_test(raw_issue(42), tracker_settings())

    assert issue.id == "42"
    assert issue.identifier == "GL-42"

    assert issue.native_ref == %{
             "id" => 1_042,
             "iid" => 42,
             "project_id" => 77,
             "project_path" => "group/project",
             "references" => %{"full" => "group/project#42"}
           }

    assert issue.title == "Issue 42"
    assert issue.description == "Body 42"
    assert issue.state == "opened"
    assert issue.url == "https://gitlab.test/group/project/-/issues/42"
    assert issue.assignee_id == "99"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    assert GitLabClient.normalize_issue_for_test(
             raw_issue(43)
             |> Map.put("state", "closed")
             |> Map.put("confidential", true)
             |> Map.put("issue_type", "incident"),
             tracker_settings()
           ).dispatchable

    assert GitLabClient.normalize_issue_for_test(
             raw_issue(45)
             |> Map.delete("assignees")
             |> Map.put("assignee", %{"username" => "fallback-user"}),
             tracker_settings()
           ).assignee_id == "fallback-user"

    assert GitLabClient.normalize_issue_for_test(
             Map.put(raw_issue(44), "title", " "),
             tracker_settings()
           ) == nil
  end

  test "client pages state reads, maps GitLab states, and drops malformed records" do
    first_page =
      Enum.map(1..98, &raw_issue/1) ++
        [Map.put(raw_issue(99), "state", "closed"), Map.put(raw_issue(100), "title", "")]

    request_fun = fn "GET", "/projects/group%2Fproject/issues", query, nil, settings ->
      send(self(), {:gitlab_page, query, settings})

      body =
        case query["page"] do
          1 -> first_page
          2 -> [raw_issue(101)]
        end

      {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 GitLabClient.fetch_issues_by_states_for_test(
                   [" OPENED "],
                   tracker_settings(),
                   request_fun
                 )

        assert length(issues) == 99
        assert hd(issues).id == "1"
        assert List.last(issues).id == "101"
        refute Enum.any?(issues, &(&1.id == "99"))
      end)

    assert log =~ "Dropping malformed GitLab issue records count=1"

    assert_receive {:gitlab_page,
                    %{
                      "state" => "opened",
                      "per_page" => 100,
                      "page" => 1,
                      "order_by" => "created_at",
                      "sort" => "asc"
                    }, %{project_path: "group/project"}}

    assert_receive {:gitlab_page, %{"page" => 2}, %{project_path: "group/project"}}

    all_request = fn "GET", "/projects/group%2Fproject/issues", query, nil, _settings ->
      send(self(), {:gitlab_all_query, query})
      {:ok, %{status: 200, body: []}}
    end

    assert {:ok, []} =
             GitLabClient.fetch_issues_by_states_for_test(
               ["opened", "closed"],
               tracker_settings(),
               all_request
             )

    assert_receive {:gitlab_all_query, %{"state" => "all"}}

    assert {:ok, []} =
             GitLabClient.fetch_issues_by_states_for_test(
               ["Todo"],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 flunk("unsupported GitLab states should not make an HTTP request")
               end
             )

    assert {:ok, []} =
             GitLabClient.fetch_issues_by_states_for_test(
               [],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 flunk("empty GitLab states should not make an HTTP request")
               end
             )
  end

  test "client refreshes IIDs in order, omits 404s, and rejects malformed refreshes" do
    request_fun = fn "GET", path, %{}, nil, _settings ->
      send(self(), {:gitlab_id_path, path})

      case path do
        "/projects/group%2Fproject/issues/2" -> {:ok, %{status: 200, body: raw_issue(2)}}
        "/projects/group%2Fproject/issues/1" -> {:ok, %{status: 200, body: raw_issue(1)}}
        "/projects/group%2Fproject/issues/404" -> {:ok, %{status: 404, body: %{"message" => "404 Not Found"}}}
      end
    end

    assert {:ok, issues} =
             GitLabClient.fetch_issues_by_ids_for_test(
               ["2", "1", "404", "2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["2", "1"]
    assert_receive {:gitlab_id_path, "/projects/group%2Fproject/issues/2"}
    assert_receive {:gitlab_id_path, "/projects/group%2Fproject/issues/1"}
    assert_receive {:gitlab_id_path, "/projects/group%2Fproject/issues/404"}
    refute_receive {:gitlab_id_path, "/projects/group%2Fproject/issues/2"}

    assert {:error, :invalid_gitlab_issue_id} =
             GitLabClient.fetch_issues_by_ids_for_test(
               ["not-a-number"],
               tracker_settings(),
               request_fun
             )

    assert {:error, :gitlab_unknown_payload} =
             GitLabClient.fetch_issues_by_ids_for_test(
               ["3"],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 {:ok, %{status: 200, body: Map.put(raw_issue(3), "title", "")}}
               end
             )

    assert {:ok, []} =
             GitLabClient.fetch_issues_by_ids_for_test(
               [],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 flunk("empty GitLab IDs should not make an HTTP request")
               end
             )
  end

  test "gitlab_api preserves REST status and body while rejecting unsafe arguments" do
    test_pid = self()
    tracker_settings = tracker_settings()

    response =
      GitLabAgentTool.execute(
        "gitlab_api",
        %{
          "method" => "post",
          "path" => " /projects/group%2Fproject/issues/42/notes ",
          "query" => %{"per_page" => 10},
          "body" => %{"body" => "hello"}
        },
        tracker_settings: tracker_settings,
        gitlab_client: fn method, path, query, body, opts ->
          send(test_pid, {:gitlab_tool_called, method, path, query, body, opts})
          {:ok, %{status: 201, body: %{"id" => 9}}}
        end
      )

    assert_received {:gitlab_tool_called, "POST", "/projects/group%2Fproject/issues/42/notes", query, body, opts}

    assert query == %{"per_page" => 10}
    assert body == %{"body" => "hello"}
    assert opts == [tracker_settings: tracker_settings]
    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"id" => 9}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    failure =
      GitLabAgentTool.execute(
        "gitlab_api",
        %{"method" => "GET", "path" => "/projects/1/issues/404"},
        gitlab_client: fn _method, _path, _query, _body, _opts ->
          {:ok, %{status: 404, body: %{"message" => "404 Not Found"}}}
        end
      )

    assert failure["success"] == false

    assert Jason.decode!(failure["output"]) == %{
             "status" => 404,
             "body" => %{"message" => "404 Not Found"}
           }

    Enum.each(
      [
        %{"method" => "GET", "path" => "https://gitlab.com/api/v4/user"},
        %{"method" => "PATCH", "path" => "/user"},
        %{"method" => "GET", "path" => "/user", "query" => false},
        %{"path" => "/user"}
      ],
      fn arguments ->
        invalid =
          GitLabAgentTool.execute(
            "gitlab_api",
            arguments,
            gitlab_client: fn _method, _path, _query, _body, _opts ->
              flunk("invalid gitlab_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )
  end

  test "gitlab_api reports unsupported tools, malformed calls, and client failures" do
    unsupported = GitLabAgentTool.execute("not_gitlab_api", %{}, [])
    assert unsupported["success"] == false
    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["gitlab_api"]

    Enum.each(
      ["not-an-object", %{"method" => "GET", "path" => 123}],
      fn arguments ->
        invalid =
          GitLabAgentTool.execute(
            "gitlab_api",
            arguments,
            gitlab_client: fn _method, _path, _query, _body, _opts ->
              flunk("malformed gitlab_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )

    malformed_response =
      GitLabAgentTool.execute(
        "gitlab_api",
        %{"method" => "GET", "path" => "/user"},
        gitlab_client: fn _method, _path, _query, _body, _opts ->
          {:ok, %{status: "not-an-integer", body: %{}}}
        end
      )

    assert malformed_response["success"] == false

    Enum.each(
      [:missing_gitlab_api_key, {:gitlab_api_request, :timeout}, :unexpected_failure],
      fn reason ->
        failure =
          GitLabAgentTool.execute(
            "gitlab_api",
            %{"method" => "GET", "path" => "/user"},
            gitlab_client: fn _method, _path, _query, _body, _opts ->
              {:error, reason}
            end
          )

        assert failure["success"] == false
        assert %{"error" => %{"message" => message}} = Jason.decode!(failure["output"])
        assert is_binary(message)
      end
    )

    non_json_body =
      GitLabAgentTool.execute(
        "gitlab_api",
        %{"method" => "GET", "path" => "/user"},
        gitlab_client: fn _method, _path, _query, _body, _opts ->
          {:ok, %{status: 200, body: self()}}
        end
      )

    assert non_json_body["success"]
    assert non_json_body["output"] =~ "#PID"
  end

  test "tracker binds GitLab tools and token env names from provider config" do
    token_env = "SYMPHONY_GITLAB_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_gitlab_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == GitLabAdapter
    assert binding.secret_environment_names == ["GITLAB_PAT", "GITLAB_ACCESS_TOKEN", token_env]
    assert [%{"name" => "gitlab_api"}] = binding.tool_specs
    assert :ok = Config.validate!()
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "gitlab",
      provider:
        Map.merge(
          %{
            "project_path" => "group/project",
            "api_key" => "test-token"
          },
          provider_overrides
        ),
      active_states: ["opened"],
      terminal_states: ["closed"]
    }
  end

  defp raw_issue(iid) do
    %{
      "iid" => iid,
      "id" => 1_000 + iid,
      "project_id" => 77,
      "title" => "Issue #{iid}",
      "description" => " Body #{iid} ",
      "state" => "opened",
      "web_url" => "https://gitlab.test/group/project/-/issues/#{iid}",
      "assignees" => [%{"id" => 99, "username" => "octocat"}],
      "assignee" => %{"username" => "octocat"},
      "labels" => [" Bug ", "bug", "Platform"],
      "references" => %{"full" => "group/project##{iid}"},
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  defp write_gitlab_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: gitlab
        provider:
          project_path: "group/project"
          api_key: #{Jason.encode!(token)}
        active_states: ["opened"]
        terminal_states: ["closed"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
