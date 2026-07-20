defmodule SymphonyElixir.Jira.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Jira.Adapter, as: JiraAdapter
  alias SymphonyElixir.Jira.AgentTool, as: JiraAgentTool
  alias SymphonyElixir.Jira.Client, as: JiraClient

  defmodule FakeJiraClient do
    def fetch_issues_by_states(states) do
      send(self(), {:jira_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:jira_ids_called, ids})
      {:ok, ids}
    end
  end

  setup do
    jira_client_module = Application.get_env(:symphony_elixir, :jira_client_module)

    on_exit(fn ->
      if is_nil(jira_client_module) do
        Application.delete_env(:symphony_elixir, :jira_client_module)
      else
        Application.put_env(:symphony_elixir, :jira_client_module, jira_client_module)
      end
    end)

    :ok
  end

  test "adapter validates Jira config, delegates reads, and advertises jira_rest" do
    settings = tracker_settings()

    assert :ok = JiraAdapter.validate_config(settings)
    assert :ok = JiraAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :missing_jira_active_states} =
             JiraAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_jira_terminal_states} =
             JiraAdapter.validate_config(%{settings | terminal_states: nil})

    assert {:error, :invalid_jira_states} =
             JiraAdapter.validate_config(%{settings | active_states: [" "]})

    assert {:error, :invalid_jira_states} =
             JiraAdapter.validate_config(%{settings | active_states: [42]})

    Application.put_env(:symphony_elixir, :jira_client_module, FakeJiraClient)

    assert {:ok, ["To Do"]} = JiraAdapter.fetch_issues_by_states(["To Do"])
    assert_receive {:jira_states_called, ["To Do"]}

    assert {:ok, ["10001"]} = JiraAdapter.fetch_issues_by_ids(["10001"])
    assert_receive {:jira_ids_called, ["10001"]}

    assert [%{"name" => "jira_rest"}] = JiraAdapter.agent_tool_specs()

    assert JiraAdapter.execute_agent_tool(
             "jira_rest",
             %{"method" => "GET", "path" => "/rest/api/3/myself"},
             jira_client: fn _method, _path, _query, _body, _opts ->
               {:ok, %{status: 200, body: %{"accountId" => "user"}}}
             end
           )["success"]
  end

  test "client validates provider settings and declares token environments" do
    assert :ok = JiraClient.validate_settings(tracker_settings())

    assert {:error, :invalid_jira_base_url} =
             JiraClient.validate_settings(tracker_settings(%{"base_url" => "http://jira.test"}))

    assert {:error, :missing_jira_email} =
             JiraClient.validate_settings(tracker_settings(%{"email" => 123}))

    assert {:error, :missing_jira_api_token} =
             JiraClient.validate_settings(tracker_settings(%{"api_token" => 123}))

    assert {:error, :missing_jira_project_key} =
             JiraClient.validate_settings(tracker_settings(%{"project_key" => 123}))

    assert JiraClient.secret_environment_names(tracker_settings(%{"api_token" => "$SYMPHONY_JIRA_TOKEN"})) == ["JIRA_API_TOKEN", "SYMPHONY_JIRA_TOKEN"]
  end

  test "client normalizes Jira issue fields and projects ADF description text" do
    issue = JiraClient.normalize_issue_for_test(raw_issue("10001", "SYM-1"), tracker_settings())

    assert issue.id == "10001"
    assert issue.identifier == "SYM-1"
    assert issue.native_ref == nil
    assert issue.title == "Issue SYM-1"
    assert issue.description == "First line\nSecond line"
    assert issue.priority == nil
    assert issue.state == "To Do"
    assert issue.branch_name == nil
    assert issue.url == "https://jira.example.test/browse/SYM-1"
    assert issue.assignee_id == "account-1"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    assert JiraClient.normalize_issue_for_test(
             put_in(raw_issue("10002", "SYM-2"), ["fields", "summary"], ""),
             tracker_settings()
           ) == nil

    rich_description =
      %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "paragraph",
            "content" => [
              %{"type" => "mention", "attrs" => %{"text" => "@Alex"}},
              %{"type" => "emoji", "attrs" => %{"shortName" => ":wave:"}},
              %{"type" => "status", "attrs" => %{"text" => "Ready"}},
              %{"type" => "inlineCard", "attrs" => %{"url" => "https://example.test/card"}}
            ]
          }
        ]
      }

    rich_issue =
      raw_issue("10003", "SYM-3")
      |> put_in(["fields", "description"], rich_description)

    assert JiraClient.normalize_issue_for_test(rich_issue, tracker_settings()).description ==
             "@Alex:wave:Readyhttps://example.test/card"

    panel_description =
      %{
        "type" => "doc",
        "version" => 1,
        "content" => [
          %{
            "type" => "panel",
            "attrs" => %{"panelType" => "info"},
            "content" => [
              %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "Panel text"}]}
            ]
          }
        ]
      }

    panel_issue =
      raw_issue("10004", "SYM-4")
      |> put_in(["fields", "description"], panel_description)

    assert JiraClient.normalize_issue_for_test(panel_issue, tracker_settings()).description ==
             "Panel text"

    assert %Issue{id: "10001"} =
             JiraClient.normalize_issue_for_test(
               raw_issue("10001", "SYM-1"),
               tracker_settings(%{"project_key" => "sym"})
             )
  end

  test "client retains inward Blocks links and gates only ready Jira issues" do
    active_blocker = linked_issue("20001", "SYM-10", "In Progress")
    terminal_blocker = linked_issue("20002", "OTHER-20", "Ready for Release")

    issue =
      raw_issue("10001", "SYM-1")
      |> put_in(
        [
          "fields",
          "issuelinks"
        ],
        [
          %{"type" => %{"name" => " Blocks "}, "inwardIssue" => active_blocker},
          %{"type" => %{"name" => "blocks"}, "inwardIssue" => terminal_blocker},
          %{
            "type" => %{"name" => "Relates"},
            "inwardIssue" => linked_issue("20003", "SYM-30", "In Progress")
          },
          %{
            "type" => %{"name" => "Blocks"},
            "outwardIssue" => linked_issue("20004", "SYM-40", "In Progress")
          }
        ]
      )

    normalized = JiraClient.normalize_issue_for_test(issue, tracker_settings())

    assert normalized.blocked_by == [
             %{id: "20001", identifier: "SYM-10", state: "In Progress"},
             %{id: "20002", identifier: "OTHER-20", state: "Ready for Release"}
           ]

    refute normalized.dispatchable

    terminal_only =
      issue
      |> put_in(["fields", "issuelinks"], [
        %{"type" => %{"name" => "Blocks"}, "inwardIssue" => terminal_blocker}
      ])
      |> JiraClient.normalize_issue_for_test(%{
        tracker_settings()
        | terminal_states: ["Ready for Release"]
      })

    assert terminal_only.dispatchable

    unknown_blocker =
      issue
      |> put_in(["fields", "status", "name"], "Todo")
      |> put_in(["fields", "issuelinks"], [
        %{
          "type" => %{"name" => "Blocks"},
          "inwardIssue" => %{"id" => "20005"}
        }
      ])
      |> JiraClient.normalize_issue_for_test(tracker_settings())

    assert unknown_blocker.blocked_by == [%{id: "20005", identifier: nil, state: nil}]
    refute unknown_blocker.dispatchable

    in_progress =
      issue
      |> put_in(["fields", "status", "name"], "In Progress")
      |> JiraClient.normalize_issue_for_test(tracker_settings())

    assert in_progress.dispatchable
  end

  test "client pages enhanced search, filters states, and drops malformed candidates" do
    request_fun = fn "POST", "/rest/api/3/search/jql", %{}, body, settings ->
      send(self(), {:jira_search, body, settings})

      response_body =
        case Map.get(body, "nextPageToken") do
          nil ->
            %{
              "issues" => [
                raw_issue("10001", "SYM-1"),
                put_in(raw_issue("10002", "SYM-2"), ["fields", "summary"], ""),
                raw_issue("10003", "SYM-3", "Done")
              ],
              "isLast" => false,
              "nextPageToken" => "next-page"
            }

          "next-page" ->
            %{"issues" => [raw_issue("10004", "SYM-4")], "isLast" => true}
        end

      {:ok, %{status: 200, body: response_body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 JiraClient.fetch_issues_by_states_for_test(
                   ["To Do"],
                   tracker_settings(),
                   request_fun
                 )

        assert Enum.map(issues, & &1.id) == ["10001", "10004"]
      end)

    assert log =~ "Dropping malformed Jira issue records count=1"

    assert_receive {:jira_search,
                    %{
                      "jql" => "project = \"SYM\" AND status IN (\"To Do\")",
                      "fields" => fields,
                      "maxResults" => 100
                    }, %{project_key: "SYM"}}

    assert "summary" in fields
    assert "issuelinks" in fields
    assert_receive {:jira_search, %{"nextPageToken" => "next-page"}, %{project_key: "SYM"}}

    assert {:ok, []} =
             JiraClient.fetch_issues_by_states_for_test(
               [],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 flunk("empty Jira states should not make an HTTP request")
               end
             )
  end

  test "client errors when enhanced search pagination omits its token" do
    assert {:error, :jira_missing_next_page_token} =
             JiraClient.fetch_issues_by_states_for_test(
               ["To Do"],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 {:ok, %{status: 200, body: %{"issues" => [], "isLast" => false}}}
               end
             )
  end

  test "client refreshes IDs in batches, preserves order, and omits missing scope" do
    ids = Enum.map(1..101, &Integer.to_string/1)

    request_fun = fn "POST", "/rest/api/3/issue/bulkfetch", %{}, body, _settings ->
      assert "issuelinks" in body["fields"]
      send(self(), {:jira_bulk_ids, body["issueIdsOrKeys"]})
      issues = Enum.map(body["issueIdsOrKeys"], &raw_issue(&1, "SYM-#{&1}"))
      {:ok, %{status: 200, body: %{"issues" => issues}}}
    end

    assert {:ok, issues} =
             JiraClient.fetch_issues_by_ids_for_test(ids, tracker_settings(), request_fun)

    assert Enum.map(issues, & &1.id) == ids
    assert_receive {:jira_bulk_ids, first_batch}
    assert length(first_batch) == 100
    assert_receive {:jira_bulk_ids, ["101"]}

    scoped_request_fun = fn _method, _path, _query, _body, _settings ->
      {:ok,
       %{
         status: 200,
         body: %{
           "issues" => [
             raw_issue("1", "SYM-1"),
             raw_issue("2", "OTHER-2", "To Do", "OTHER")
           ]
         }
       }}
    end

    assert {:ok, [%Issue{id: "1"}]} =
             JiraClient.fetch_issues_by_ids_for_test(
               ["1", "2", "404"],
               tracker_settings(),
               scoped_request_fun
             )

    assert {:error, :jira_unknown_payload} =
             JiraClient.fetch_issues_by_ids_for_test(
               ["1"],
               tracker_settings(),
               fn _method, _path, _query, _body, _settings ->
                 malformed = put_in(raw_issue("1", "SYM-1"), ["fields", "summary"], "")
                 {:ok, %{status: 200, body: %{"issues" => [malformed]}}}
               end
             )
  end

  test "client refreshes Jira blockers before dispatch" do
    request_fun = fn "POST", "/rest/api/3/issue/bulkfetch", %{}, body, _settings ->
      assert "issuelinks" in body["fields"]

      issue =
        raw_issue("10001", "SYM-1")
        |> put_in(["fields", "issuelinks"], [
          %{
            "type" => %{"name" => "Blocks"},
            "inwardIssue" => linked_issue("20001", "SYM-10", "In Progress")
          }
        ])

      {:ok, %{status: 200, body: %{"issues" => [issue]}}}
    end

    assert {:ok, [issue]} =
             JiraClient.fetch_issues_by_ids_for_test(
               ["10001"],
               tracker_settings(),
               request_fun
             )

    assert issue.blocked_by == [
             %{id: "20001", identifier: "SYM-10", state: "In Progress"}
           ]

    refute issue.dispatchable
  end

  test "jira_rest preserves REST status and body while rejecting unsafe arguments" do
    test_pid = self()
    tracker_settings = tracker_settings()

    response =
      JiraAgentTool.execute(
        "jira_rest",
        %{
          "method" => "post",
          "path" => " /rest/api/3/issue/10001/comment ",
          "query" => %{"expand" => "renderedBody"},
          "body" => %{"body" => %{"type" => "doc"}}
        },
        tracker_settings: tracker_settings,
        jira_client: fn method, path, query, body, opts ->
          send(test_pid, {:jira_tool_called, method, path, query, body, opts})
          {:ok, %{status: 201, body: %{"id" => "comment-1"}}}
        end
      )

    expected_call =
      {:jira_tool_called, "POST", "/rest/api/3/issue/10001/comment", %{"expand" => "renderedBody"}, %{"body" => %{"type" => "doc"}}, [tracker_settings: tracker_settings]}

    assert_received ^expected_call

    assert response["success"]
    assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"id" => "comment-1"}}

    failure =
      JiraAgentTool.execute(
        "jira_rest",
        %{"method" => "GET", "path" => "/rest/api/3/issue/404"},
        jira_client: fn _method, _path, _query, _body, _opts ->
          {:ok, %{status: 404, body: %{"errorMessages" => ["Not Found"]}}}
        end
      )

    refute failure["success"]

    Enum.each(
      [
        %{"method" => "GET", "path" => "https://jira.test/rest/api/3/myself"},
        %{"method" => "GET", "path" => "/rest/api/2/myself"},
        %{"method" => "GET", "path" => "/rest/api/3/myself", "query" => false},
        %{"path" => "/rest/api/3/myself"}
      ],
      fn arguments ->
        invalid =
          JiraAgentTool.execute(
            "jira_rest",
            arguments,
            jira_client: fn _method, _path, _query, _body, _opts ->
              flunk("invalid jira_rest arguments should not call the client")
            end
          )

        refute invalid["success"]
      end
    )
  end

  test "jira_rest reports unsupported tools, malformed calls, and client failures" do
    unsupported = JiraAgentTool.execute("not_jira_rest", %{}, [])
    refute unsupported["success"]
    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["jira_rest"]

    Enum.each(["not-an-object", %{"method" => "GET", "path" => 123}], fn arguments ->
      invalid =
        JiraAgentTool.execute(
          "jira_rest",
          arguments,
          jira_client: fn _method, _path, _query, _body, _opts ->
            flunk("malformed jira_rest arguments should not call the client")
          end
        )

      refute invalid["success"]
    end)

    malformed_response =
      JiraAgentTool.execute(
        "jira_rest",
        %{"method" => "GET", "path" => "/rest/api/3/myself"},
        jira_client: fn _method, _path, _query, _body, _opts ->
          {:ok, %{status: "bad", body: %{}}}
        end
      )

    refute malformed_response["success"]

    Enum.each([:missing_jira_api_token, {:jira_api_request, :timeout}, :unexpected], fn reason ->
      failure =
        JiraAgentTool.execute(
          "jira_rest",
          %{"method" => "GET", "path" => "/rest/api/3/myself"},
          jira_client: fn _method, _path, _query, _body, _opts -> {:error, reason} end
        )

      refute failure["success"]
      assert %{"error" => %{"message" => message}} = Jason.decode!(failure["output"])
      assert is_binary(message)
    end)

    non_json_body =
      JiraAgentTool.execute(
        "jira_rest",
        %{"method" => "GET", "path" => "/rest/api/3/myself"},
        jira_client: fn _method, _path, _query, _body, _opts ->
          {:ok, %{status: 200, body: self()}}
        end
      )

    assert non_json_body["success"]
    assert non_json_body["output"] =~ "#PID"
  end

  test "tracker binds Jira tools and token env names from provider config" do
    token_env = "SYMPHONY_JIRA_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_jira_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == JiraAdapter
    assert binding.secret_environment_names == ["JIRA_API_TOKEN", token_env]
    assert [%{"name" => "jira_rest"}] = binding.tool_specs
    assert :ok = Config.validate!()
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "jira",
      provider:
        Map.merge(
          %{
            "base_url" => "https://jira.example.test",
            "email" => "agent@example.test",
            "api_token" => "test-token",
            "project_key" => "SYM"
          },
          provider_overrides
        ),
      active_states: ["To Do"],
      terminal_states: ["Done"]
    }
  end

  defp raw_issue(id, key, state \\ "To Do", project_key \\ "SYM") do
    %{
      "id" => id,
      "key" => key,
      "fields" => %{
        "summary" => "Issue #{key}",
        "description" => %{
          "type" => "doc",
          "version" => 1,
          "content" => [
            %{
              "type" => "paragraph",
              "content" => [
                %{"type" => "text", "text" => "First line"},
                %{"type" => "hardBreak"},
                %{"type" => "text", "text" => "Second line"}
              ]
            }
          ]
        },
        "status" => %{"name" => state},
        "labels" => [" Bug ", "bug", "Platform"],
        "assignee" => %{"accountId" => "account-1"},
        "created" => "2026-01-01T00:00:00.000+0000",
        "updated" => "2026-01-02T00:00:00.000+0000",
        "project" => %{"key" => project_key}
      }
    }
  end

  defp linked_issue(id, key, state) do
    %{
      "id" => id,
      "key" => key,
      "fields" => %{"status" => %{"name" => state}}
    }
  end

  defp write_jira_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: jira
        provider:
          base_url: "https://jira.example.test"
          email: "agent@example.test"
          api_token: #{Jason.encode!(token)}
          project_key: "SYM"
        active_states: ["To Do"]
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
