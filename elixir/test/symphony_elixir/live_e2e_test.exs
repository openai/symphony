defmodule SymphonyElixir.LiveE2ETest do
  use SymphonyElixir.TestSupport

  require Logger

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  @default_team_key "SYME2E"
  @result_file "LIVE_E2E_RESULT.txt"
  @live_e2e_skip_reason (cond do
                           System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1" ->
                             "set SYMPHONY_RUN_LIVE_E2E=1 to enable the real Linear/Codex end-to-end test"

                           is_nil(System.find_executable("codex")) ->
                             "real Codex live test requires `codex` on PATH"

                           System.get_env("LINEAR_API_KEY") in [nil, ""] ->
                             "real Linear live test requires LINEAR_API_KEY"

                           true ->
                             nil
                         end)

  @team_query """
  query SymphonyLiveE2ETeam($key: String!) {
    teams(filter: {key: {eq: $key}}, first: 1) {
      nodes {
        id
        key
        name
        states(first: 50) {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @create_project_mutation """
  mutation SymphonyLiveE2ECreateProject($name: String!, $teamIds: [String!]!) {
    projectCreate(input: {name: $name, teamIds: $teamIds}) {
      success
      project {
        id
        name
        slugId
        url
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyLiveE2ECreateIssue(
    $teamId: String!
    $projectId: String!
    $title: String!
    $description: String!
    $stateId: String
  ) {
    issueCreate(
      input: {
        teamId: $teamId
        projectId: $projectId
        title: $title
        description: $description
        stateId: $stateId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        url
        state {
          name
        }
      }
    }
  }
  """

  @project_statuses_query """
  query SymphonyLiveE2EProjectStatuses {
    projectStatuses(first: 50) {
      nodes {
        id
        name
        type
      }
    }
  }
  """

  @issue_details_query """
  query SymphonyLiveE2EIssueDetails($id: String!) {
    issue(id: $id) {
      id
      identifier
      state {
        name
        type
      }
      comments(first: 20) {
        nodes {
          body
        }
      }
    }
  }
  """

  @complete_project_mutation """
  mutation SymphonyLiveE2ECompleteProject($id: String!, $statusId: String!, $completedAt: DateTime!) {
    projectUpdate(id: $id, input: {statusId: $statusId, completedAt: $completedAt}) {
      success
    }
  }
  """

  @tag skip: @live_e2e_skip_reason
  test "creates a real Linear project and issue, then runs a real Codex turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-live-e2e-#{System.unique_integer([:positive])}"
      )

    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    workspace_root = Path.join(test_root, "workspaces")
    team_key = System.get_env("SYMPHONY_LIVE_LINEAR_TEAM_KEY") || @default_team_key
    codex_command = System.get_env("SYMPHONY_LIVE_CODEX_COMMAND") || "codex app-server"
    original_workflow_path = Workflow.workflow_file_path()

    File.mkdir_p!(workflow_root)

    try do
      Workflow.set_workflow_file_path(workflow_file)

      write_workflow_file!(workflow_file,
        tracker_api_token: "$LINEAR_API_KEY",
        tracker_project_slug: "bootstrap",
        workspace_root: workspace_root,
        codex_command: codex_command,
        codex_approval_policy: "never",
        observability_enabled: false
      )

      team = fetch_team!(team_key)
      active_state = active_state!(team)
      completed_project_status = completed_project_status!()
      terminal_states = terminal_state_names(team)

      project =
        create_project!(
          team["id"],
          "Symphony Live E2E #{System.unique_integer([:positive])}"
        )

      issue =
        create_issue!(
          team["id"],
          project["id"],
          active_state["id"],
          "Symphony live e2e issue for #{project["name"]}"
        )

      write_workflow_file!(workflow_file,
        tracker_api_token: "$LINEAR_API_KEY",
        tracker_project_slug: project["slugId"],
        tracker_active_states: [active_state["name"]],
        tracker_terminal_states: terminal_states,
        workspace_root: workspace_root,
        codex_command: codex_command,
        codex_approval_policy: "never",
        codex_turn_timeout_ms: 600_000,
        codex_stall_timeout_ms: 600_000,
        observability_enabled: false,
        prompt: live_prompt(project["slugId"])
      )

      assert :ok = AgentRunner.run(issue, nil, max_turns: 1)

      result_path = Path.join([workspace_root, issue.identifier, @result_file])
      assert File.exists?(result_path)
      assert File.read!(result_path) == expected_result(issue.identifier, project["slugId"])

      issue_snapshot = fetch_issue_details!(issue.id)
      assert issue_completed?(issue_snapshot)
      assert issue_has_comment?(issue_snapshot, expected_comment(issue.identifier, project["slugId"]))

      assert :ok = complete_project(project["id"], completed_project_status["id"])
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(test_root)
    end
  end

  defp fetch_team!(team_key) do
    @team_query
    |> graphql_data!(%{key: team_key})
    |> get_in(["teams", "nodes"])
    |> case do
      [team | _] ->
        team

      _ ->
        flunk("expected Linear team #{inspect(team_key)} to exist")
    end
  end

  defp active_state!(%{"states" => %{"nodes" => states}}) when is_list(states) do
    Enum.find(states, &(&1["type"] == "started")) ||
      Enum.find(states, &(&1["type"] == "unstarted")) ||
      Enum.find(states, &(&1["type"] not in ["completed", "canceled"])) ||
      flunk("expected team to expose at least one non-terminal workflow state")
  end

  defp terminal_state_names(%{"states" => %{"nodes" => states}}) when is_list(states) do
    states
    |> Enum.filter(&(&1["type"] in ["completed", "canceled"]))
    |> Enum.map(& &1["name"])
    |> case do
      [] -> ["Done", "Canceled", "Cancelled"]
      names -> names
    end
  end

  defp completed_project_status! do
    @project_statuses_query
    |> graphql_data!(%{})
    |> get_in(["projectStatuses", "nodes"])
    |> case do
      statuses when is_list(statuses) ->
        Enum.find(statuses, &(&1["type"] == "completed")) ||
          flunk("expected workspace to expose a completed project status")

      payload ->
        flunk("expected project statuses list, got: #{inspect(payload)}")
    end
  end

  defp create_project!(team_id, name) do
    @create_project_mutation
    |> graphql_data!(%{teamIds: [team_id], name: name})
    |> fetch_successful_entity!("projectCreate", "project")
  end

  defp create_issue!(team_id, project_id, state_id, title) do
    issue =
      @create_issue_mutation
      |> graphql_data!(%{
        teamId: team_id,
        projectId: project_id,
        title: title,
        description: title,
        stateId: state_id
      })
      |> fetch_successful_entity!("issueCreate", "issue")

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      state: get_in(issue, ["state", "name"]),
      url: issue["url"],
      labels: [],
      blocked_by: []
    }
  end

  defp complete_project(project_id, completed_status_id)
       when is_binary(project_id) and is_binary(completed_status_id) do
    update_entity(
      @complete_project_mutation,
      %{
        id: project_id,
        statusId: completed_status_id,
        completedAt: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      },
      "projectUpdate",
      "project"
    )
  end

  defp fetch_issue_details!(issue_id) when is_binary(issue_id) do
    @issue_details_query
    |> graphql_data!(%{id: issue_id})
    |> get_in(["issue"])
    |> case do
      %{} = issue -> issue
      payload -> flunk("expected issue details payload, got: #{inspect(payload)}")
    end
  end

  defp issue_completed?(%{"state" => %{"type" => type}}), do: type in ["completed", "canceled"]
  defp issue_completed?(_issue), do: false

  defp issue_has_comment?(%{"comments" => %{"nodes" => comments}}, expected_body) when is_list(comments) do
    Enum.any?(comments, &(&1["body"] == expected_body))
  end

  defp issue_has_comment?(_issue, _expected_body), do: false

  defp update_entity(mutation, variables, mutation_name, entity_name) do
    case Client.graphql(mutation, variables) do
      {:ok, %{"data" => %{^mutation_name => %{"success" => true}}}} ->
        :ok

      {:ok, %{"errors" => errors}} ->
        Logger.warning("Live e2e finalization failed for #{entity_name}: #{inspect(errors)}")
        :ok

      {:ok, payload} ->
        Logger.warning("Live e2e finalization failed for #{entity_name}: #{inspect(payload)}")
        :ok

      {:error, reason} ->
        Logger.warning("Live e2e finalization failed for #{entity_name}: #{inspect(reason)}")
        :ok
    end
  end

  defp graphql_data!(query, variables) when is_binary(query) and is_map(variables) do
    case Client.graphql(query, variables) do
      {:ok, %{"data" => data, "errors" => errors}} when is_map(data) and is_list(errors) ->
        flunk("Linear GraphQL returned partial errors: #{inspect(errors)}")

      {:ok, %{"errors" => errors}} when is_list(errors) ->
        flunk("Linear GraphQL failed: #{inspect(errors)}")

      {:ok, %{"data" => data}} when is_map(data) ->
        data

      {:ok, payload} ->
        flunk("Linear GraphQL returned unexpected payload: #{inspect(payload)}")

      {:error, reason} ->
        flunk("Linear GraphQL request failed: #{inspect(reason)}")
    end
  end

  defp fetch_successful_entity!(data, mutation_name, entity_name)
       when is_map(data) and is_binary(mutation_name) and is_binary(entity_name) do
    case data do
      %{^mutation_name => %{"success" => true, ^entity_name => %{} = entity}} ->
        entity

      _ ->
        flunk("expected successful #{mutation_name} response, got: #{inspect(data)}")
    end
  end

  defp live_prompt(project_slug) do
    """
    You are running a real Symphony end-to-end test.

    The current working directory is the workspace root.

    Step 1:
    Create a file named #{@result_file} in the current working directory by running exactly:

    ```sh
    cat > #{@result_file} <<'EOF'
    identifier={{ issue.identifier }}
    project_slug=#{project_slug}
    EOF
    ```

    Then verify it by running:

    ```sh
    cat #{@result_file}
    ```

    The file content must be exactly:
    identifier={{ issue.identifier }}
    project_slug=#{project_slug}

    Step 2:
    Use the `linear_graphql` tool to query the current issue by `{{ issue.id }}` and read:
    - existing comments
    - team workflow states

    If the exact comment body below is not already present, post exactly one comment on the current issue with this exact body:
    #{expected_comment("{{ issue.identifier }}", project_slug)}

    Use these exact GraphQL operations:

    ```graphql
    query IssueContext($id: String!) {
      issue(id: $id) {
        comments(first: 20) {
          nodes {
            body
          }
        }
        team {
          states(first: 50) {
            nodes {
              id
              name
              type
            }
          }
        }
      }
    }
    ```

    ```graphql
    mutation AddComment($issueId: String!, $body: String!) {
      commentCreate(input: {issueId: $issueId, body: $body}) {
        success
      }
    }
    ```

    Step 3:
    Use the same issue-context query result to choose a workflow state whose `type` is `completed`.
    Then move the current issue to that state with this exact mutation:

    ```graphql
    mutation CompleteIssue($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: {stateId: $stateId}) {
        success
      }
    }
    ```

    Step 4:
    Verify all outcomes with one final `linear_graphql` query against `{{ issue.id }}`:
    - the exact comment body is present
    - the issue state type is `completed`

    Do not ask for approval.
    Stop only after all three conditions are true:
    1. the file exists with the exact contents above
    2. the Linear comment exists with the exact body above
    3. the Linear issue is in a completed terminal state
    """
  end

  defp expected_result(issue_identifier, project_slug) do
    "identifier=#{issue_identifier}\nproject_slug=#{project_slug}\n"
  end

  defp expected_comment(issue_identifier, project_slug) do
    "Symphony live e2e comment\nidentifier=#{issue_identifier}\nproject_slug=#{project_slug}"
  end
end
