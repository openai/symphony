defmodule SymphonyElixir.LiveE2ETest do
  use SymphonyElixir.TestSupport

  require Logger
  alias SymphonyElixir.SSH

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  @default_team_key "SYME2E"
  @default_docker_auth_json Path.join(System.user_home!(), ".codex/auth.json")
  @docker_worker_count 2
  @docker_support_dir Path.expand("../support/live_e2e_docker", __DIR__)
  @docker_compose_file Path.join(@docker_support_dir, "docker-compose.yml")
  @result_file "LIVE_E2E_RESULT.txt"
  @live_e2e_skip_reason if(System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1",
                          do: "set SYMPHONY_RUN_LIVE_E2E=1 to enable the real Linear/Codex end-to-end test"
                        )

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
  test "creates a real Linear project and issue with a local worker" do
    run_live_issue_flow!(:local)
  end

  @tag skip: @live_e2e_skip_reason
  test "creates a real Linear project and issue with an ssh worker" do
    run_live_issue_flow!(:ssh)
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

  defp active_state_names(%{"states" => %{"nodes" => states}}) when is_list(states) do
    states
    |> Enum.reject(&(&1["type"] in ["completed", "canceled"]))
    |> Enum.map(& &1["name"])
    |> case do
      [] -> ["Todo", "In Progress", "In Review"]
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
    You must use the `linear_graphql` tool to query the current issue by `{{ issue.id }}` and read:
    - existing comments
    - team workflow states

    A turn that only creates the file is incomplete. Do not stop after Step 1.

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

  defp receive_runtime_info!(issue_id) do
    receive do
      {:worker_runtime_info, ^issue_id, %{workspace_path: workspace_path} = runtime_info}
      when is_binary(workspace_path) ->
        runtime_info

      {:codex_worker_update, ^issue_id, _message} ->
        receive_runtime_info!(issue_id)
    after
      5_000 ->
        flunk("timed out waiting for worker runtime info for #{inspect(issue_id)}")
    end
  end

  defp read_worker_result!(%{worker_host: nil, workspace_path: workspace_path}, result_file)
       when is_binary(workspace_path) and is_binary(result_file) do
    File.read!(Path.join(workspace_path, result_file))
  end

  defp read_worker_result!(%{worker_host: worker_host, workspace_path: workspace_path}, result_file)
       when is_binary(worker_host) and is_binary(workspace_path) and is_binary(result_file) do
    remote_result_path = Path.join(workspace_path, result_file)

    case SSH.run(worker_host, "cat #{shell_escape(remote_result_path)}", stderr_to_stdout: true) do
      {:ok, {output, 0}} ->
        output

      {:ok, {output, status}} ->
        flunk("failed to read remote result from #{worker_host}:#{remote_result_path} (status #{status}): #{inspect(output)}")

      {:error, reason} ->
        flunk("failed to read remote result from #{worker_host}:#{remote_result_path}: #{inspect(reason)}")
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp run_live_issue_flow!(backend) when backend in [:local, :ssh] do
    run_id = "symphony-live-e2e-#{backend}-#{System.unique_integer([:positive])}"
    test_root = Path.join(System.tmp_dir!(), run_id)
    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    worker_setup = live_worker_setup!(backend, run_id, test_root)
    team_key = System.get_env("SYMPHONY_LIVE_LINEAR_TEAM_KEY") || @default_team_key
    original_workflow_path = Workflow.workflow_file_path()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    File.mkdir_p!(workflow_root)

    try do
      if is_pid(orchestrator_pid) do
        assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
      end

      Workflow.set_workflow_file_path(workflow_file)

      write_workflow_file!(workflow_file,
        tracker_api_token: "$LINEAR_API_KEY",
        tracker_project_slug: "bootstrap",
        workspace_root: worker_setup.workspace_root,
        worker_ssh_hosts: worker_setup.ssh_worker_hosts,
        codex_command: worker_setup.codex_command,
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
          "Symphony Live E2E #{backend} #{System.unique_integer([:positive])}"
        )

      issue =
        create_issue!(
          team["id"],
          project["id"],
          active_state["id"],
          "Symphony live e2e #{backend} issue for #{project["name"]}"
        )

      write_workflow_file!(workflow_file,
        tracker_api_token: "$LINEAR_API_KEY",
        tracker_project_slug: project["slugId"],
        tracker_active_states: active_state_names(team),
        tracker_terminal_states: terminal_states,
        workspace_root: worker_setup.workspace_root,
        worker_ssh_hosts: worker_setup.ssh_worker_hosts,
        codex_command: worker_setup.codex_command,
        codex_approval_policy: "never",
        codex_turn_timeout_ms: 600_000,
        codex_stall_timeout_ms: 600_000,
        observability_enabled: false,
        prompt: live_prompt(project["slugId"])
      )

      assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

      runtime_info = receive_runtime_info!(issue.id)

      assert read_worker_result!(runtime_info, @result_file) ==
               expected_result(issue.identifier, project["slugId"])

      issue_snapshot = fetch_issue_details!(issue.id)
      assert issue_completed?(issue_snapshot)
      assert issue_has_comment?(issue_snapshot, expected_comment(issue.identifier, project["slugId"]))

      assert :ok = complete_project(project["id"], completed_project_status["id"])
    after
      restart_orchestrator_if_needed()
      cleanup_live_worker_setup(worker_setup)
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(test_root)
    end
  end

  defp live_worker_setup!(:local, _run_id, test_root) when is_binary(test_root) do
    %{
      cleanup: fn -> :ok end,
      codex_command: "codex app-server",
      ssh_worker_hosts: [],
      workspace_root: Path.join(test_root, "workspaces")
    }
  end

  defp live_worker_setup!(:ssh, run_id, test_root) when is_binary(run_id) and is_binary(test_root) do
    case live_ssh_worker_hosts() do
      [] ->
        live_docker_worker_setup!(run_id, test_root)

      _hosts ->
        live_ssh_worker_setup!(run_id)
    end
  end

  defp cleanup_live_worker_setup(%{cleanup: cleanup}) when is_function(cleanup, 0) do
    cleanup.()
  end

  defp cleanup_live_worker_setup(_worker_setup), do: :ok

  defp restart_orchestrator_if_needed do
    if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
      case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  defp live_ssh_worker_setup!(run_id) when is_binary(run_id) do
    ssh_worker_hosts = live_ssh_worker_hosts()
    remote_test_root = Path.join(shared_remote_home!(ssh_worker_hosts), ".#{run_id}")
    remote_workspace_root = "~/.#{run_id}/workspaces"

    %{
      cleanup: fn -> cleanup_remote_test_root(remote_test_root, ssh_worker_hosts) end,
      codex_command: "codex app-server",
      ssh_worker_hosts: ssh_worker_hosts,
      workspace_root: remote_workspace_root
    }
  end

  defp live_docker_worker_setup!(run_id, test_root) when is_binary(run_id) and is_binary(test_root) do
    ssh_root = Path.join(test_root, "live-docker-ssh")
    key_path = Path.join(ssh_root, "id_ed25519")
    config_path = Path.join(ssh_root, "config")
    auth_json_path = @default_docker_auth_json
    worker_ports = reserve_tcp_ports(@docker_worker_count)
    worker_hosts = Enum.map(worker_ports, &"localhost:#{&1}")
    project_name = docker_project_name(run_id)
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    base_cleanup = fn ->
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      docker_compose_down(project_name, docker_compose_env(worker_ports, auth_json_path, key_path <> ".pub"))
    end

    result =
      try do
        File.mkdir_p!(ssh_root)
        generate_ssh_keypair!(key_path)
        write_docker_ssh_config!(config_path, key_path)
        System.put_env("SYMPHONY_SSH_CONFIG", config_path)

        docker_compose_up!(project_name, docker_compose_env(worker_ports, auth_json_path, key_path <> ".pub"))
        wait_for_ssh_hosts!(worker_hosts)
        remote_test_root = Path.join(shared_remote_home!(worker_hosts), ".#{run_id}")
        remote_workspace_root = "~/.#{run_id}/workspaces"

        %{
          cleanup: fn ->
            cleanup_remote_test_root(remote_test_root, worker_hosts)
            base_cleanup.()
          end,
          codex_command: "codex app-server",
          ssh_worker_hosts: worker_hosts,
          workspace_root: remote_workspace_root
        }
      rescue
        error ->
          {:error, error, __STACKTRACE__}
      catch
        kind, reason ->
          {:caught, kind, reason, __STACKTRACE__}
      end

    case result do
      %{ssh_worker_hosts: _hosts} = worker_setup ->
        worker_setup

      {:error, error, stacktrace} ->
        base_cleanup.()
        reraise(error, stacktrace)

      {:caught, kind, reason, stacktrace} ->
        base_cleanup.()
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp live_ssh_worker_hosts do
    System.get_env("SYMPHONY_LIVE_SSH_WORKER_HOSTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp cleanup_remote_test_root(test_root, ssh_worker_hosts)
       when is_binary(test_root) and is_list(ssh_worker_hosts) do
    Enum.each(ssh_worker_hosts, fn worker_host ->
      _ = SSH.run(worker_host, "rm -rf #{shell_escape(test_root)}", stderr_to_stdout: true)
    end)
  end

  defp shared_remote_home!([first_host | rest] = worker_hosts) when is_binary(first_host) and rest != [] do
    homes =
      worker_hosts
      |> Enum.map(fn worker_host -> {worker_host, remote_home!(worker_host)} end)

    [{_host, home} | _remaining] = homes

    if Enum.all?(homes, fn {_host, other_home} -> other_home == home end) do
      home
    else
      flunk("expected all live SSH workers to share one home directory, got: #{inspect(homes)}")
    end
  end

  defp shared_remote_home!([worker_host]) when is_binary(worker_host), do: remote_home!(worker_host)
  defp shared_remote_home!(_worker_hosts), do: flunk("expected at least one live SSH worker host")

  defp remote_home!(worker_host) when is_binary(worker_host) do
    case SSH.run(worker_host, "printf '%s\\n' \"$HOME\"", stderr_to_stdout: true) do
      {:ok, {output, 0}} ->
        output
        |> String.trim()
        |> case do
          "" -> flunk("expected non-empty remote home for #{worker_host}")
          home -> home
        end

      {:ok, {output, status}} ->
        flunk("failed to resolve remote home for #{worker_host} (status #{status}): #{inspect(output)}")

      {:error, reason} ->
        flunk("failed to resolve remote home for #{worker_host}: #{inspect(reason)}")
    end
  end

  defp reserve_tcp_ports(count) when is_integer(count) and count > 0 do
    reserve_tcp_ports(count, MapSet.new(), [])
  end

  defp reserve_tcp_ports(0, _seen, ports), do: Enum.reverse(ports)

  defp reserve_tcp_ports(remaining, seen, ports) do
    port = reserve_tcp_port!()

    if MapSet.member?(seen, port) do
      reserve_tcp_ports(remaining, seen, ports)
    else
      reserve_tcp_ports(remaining - 1, MapSet.put(seen, port), [port | ports])
    end
  end

  defp reserve_tcp_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp generate_ssh_keypair!(key_path) when is_binary(key_path) do
    case System.find_executable("ssh-keygen") do
      nil ->
        flunk("docker worker mode requires `ssh-keygen` on PATH")

      executable ->
        key_dir = Path.dirname(key_path)
        File.mkdir_p!(key_dir)
        File.rm_rf(key_path)
        File.rm_rf(key_path <> ".pub")

        case System.cmd(executable, ["-q", "-t", "ed25519", "-N", "", "-f", key_path], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> flunk("failed to generate live docker ssh key (status #{status}): #{inspect(output)}")
        end
    end
  end

  defp write_docker_ssh_config!(config_path, key_path)
       when is_binary(config_path) and is_binary(key_path) do
    config_contents = """
    Host localhost 127.0.0.1
      User root
      IdentityFile #{key_path}
      IdentitiesOnly yes
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
    """

    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, config_contents)
  end

  defp docker_project_name(run_id) when is_binary(run_id) do
    run_id
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
  end

  defp docker_compose_env(worker_ports, auth_json_path, authorized_key_path)
       when is_list(worker_ports) and is_binary(auth_json_path) and is_binary(authorized_key_path) do
    [
      {"SYMPHONY_LIVE_DOCKER_AUTH_JSON", auth_json_path},
      {"SYMPHONY_LIVE_DOCKER_AUTHORIZED_KEY", authorized_key_path},
      {"SYMPHONY_LIVE_DOCKER_WORKER_1_PORT", Integer.to_string(Enum.at(worker_ports, 0))},
      {"SYMPHONY_LIVE_DOCKER_WORKER_2_PORT", Integer.to_string(Enum.at(worker_ports, 1))}
    ]
  end

  defp docker_compose_up!(project_name, env) when is_binary(project_name) and is_list(env) do
    args = ["compose", "-f", @docker_compose_file, "-p", project_name, "up", "-d", "--build"]

    case System.cmd("docker", args, cd: @docker_support_dir, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        flunk("failed to start live docker workers (status #{status}): #{inspect(output)}")
    end
  end

  defp docker_compose_down(project_name, env) when is_binary(project_name) and is_list(env) do
    _ =
      System.cmd(
        "docker",
        ["compose", "-f", @docker_compose_file, "-p", project_name, "down", "-v", "--remove-orphans"],
        cd: @docker_support_dir,
        env: env,
        stderr_to_stdout: true
      )

    :ok
  end

  defp wait_for_ssh_hosts!(worker_hosts) when is_list(worker_hosts) do
    deadline = System.monotonic_time(:millisecond) + 60_000

    Enum.each(worker_hosts, fn worker_host ->
      wait_for_ssh_host!(worker_host, deadline)
    end)
  end

  defp wait_for_ssh_host!(worker_host, deadline_ms) when is_binary(worker_host) do
    case SSH.run(worker_host, "printf ready", stderr_to_stdout: true) do
      {:ok, {"ready", 0}} ->
        :ok

      {:ok, {_output, _status}} ->
        retry_or_flunk_ssh_host(worker_host, deadline_ms)

      {:error, _reason} ->
        retry_or_flunk_ssh_host(worker_host, deadline_ms)
    end
  end

  defp retry_or_flunk_ssh_host(worker_host, deadline_ms) do
    if System.monotonic_time(:millisecond) < deadline_ms do
      Process.sleep(1_000)
      wait_for_ssh_host!(worker_host, deadline_ms)
    else
      flunk("timed out waiting for SSH worker #{worker_host} to accept connections")
    end
  end
end
