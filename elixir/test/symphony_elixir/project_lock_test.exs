defmodule SymphonyElixir.ProjectLockTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias SymphonyElixir.{ProjectLock, Workflow}

  setup do
    unique =
      6
      |> :crypto.strong_rand_bytes()
      |> Base.encode16(case: :lower)

    lock_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-project-lock-test-#{System.system_time(:nanosecond)}-#{unique}"
      )

    File.rm_rf(lock_root)
    File.mkdir_p!(lock_root)
    on_exit(fn -> File.rm_rf(lock_root) end)

    {:ok, lock_root: lock_root}
  end

  test "blocks a second startup for the same project until the first one exits", %{lock_root: lock_root} do
    pid_probe = fn pid -> pid == 11_111 end

    {:ok, first_pid} =
      start_supervised(
        temporary_child_spec(
          Module.concat(__MODULE__, :FirstSameProject),
          project_lock_opts(
            name: Module.concat(__MODULE__, :FirstSameProject),
            project_slug: "same-project",
            lock_root: lock_root,
            os_pid: "11111",
            pid_alive?: pid_probe
          )
        )
      )

    assert {:error, {:project_already_running, owner}} =
             trap_start_link(fn ->
               ProjectLock.start_link(
                 project_lock_opts(
                   name: Module.concat(__MODULE__, :SecondSameProject),
                   project_slug: "same-project",
                   lock_root: lock_root,
                   os_pid: "22222",
                   pid_alive?: pid_probe
                 )
               )
             end)

    assert owner.project_slug == "same-project"
    assert owner.pid == 11_111

    GenServer.stop(first_pid)

    assert {:ok, second_pid} =
             ProjectLock.start_link(
               project_lock_opts(
                 name: Module.concat(__MODULE__, :ThirdSameProject),
                 project_slug: "same-project",
                 lock_root: lock_root,
                 os_pid: "22222",
                 pid_alive?: fn _pid -> false end
               )
             )

    GenServer.stop(second_pid)
  end

  test "allows concurrent startups for different projects", %{lock_root: lock_root} do
    {:ok, _first_pid} =
      start_supervised(
        {ProjectLock,
         project_lock_opts(
           name: Module.concat(__MODULE__, :ProjectOne),
           project_slug: "project-one",
           lock_root: lock_root,
           os_pid: "10001"
         )}
      )

    assert {:ok, second_pid} =
             ProjectLock.start_link(
               project_lock_opts(
                 name: Module.concat(__MODULE__, :ProjectTwo),
                 project_slug: "project-two",
                 lock_root: lock_root,
                 os_pid: "10002"
               )
             )

    GenServer.stop(second_pid)
  end

  test "reclaims a stale lock when the recorded pid is no longer alive", %{lock_root: lock_root} do
    lock_path = ProjectLock.lock_path_for_test("stale-project", lock_root)
    File.mkdir_p!(lock_path)

    File.write!(
      Path.join(lock_path, "owner.json"),
      Jason.encode!(%{
        instance_id: "stale-owner",
        project_slug: "stale-project",
        hostname: "old-host",
        pid: 99_999,
        workflow_path: "/tmp/stale-workflow.md",
        cwd: "/tmp/stale-workspace",
        started_at: "2026-02-27T22:30:00Z"
      })
    )

    assert {:ok, pid} =
             ProjectLock.start_link(
               project_lock_opts(
                 name: Module.concat(__MODULE__, :RecoveredProject),
                 project_slug: "stale-project",
                 lock_root: lock_root,
                 os_pid: "33333",
                 pid_alive?: fn _pid -> false end
               )
             )

    owner =
      lock_path
      |> Path.join("owner.json")
      |> File.read!()
      |> Jason.decode!()

    assert owner["project_slug"] == "stale-project"
    assert owner["pid"] == 33_333
    refute owner["instance_id"] == "stale-owner"

    GenServer.stop(pid)
  end

  test "skips locking when the tracker is not linear" do
    assert {:ok, pid} =
             ProjectLock.start_link(
               project_lock_opts(
                 name: Module.concat(__MODULE__, :MemoryTracker),
                 tracker_kind: "memory",
                 project_slug: nil
               )
             )

    assert %{lock_path: nil, metadata_path: nil, owner: nil} = :sys.get_state(pid)
    GenServer.stop(pid)
  end

  test "surfaces metadata-unavailable details when the lock owner file is unreadable", %{lock_root: lock_root} do
    lock_path = ProjectLock.lock_path_for_test("broken-project", lock_root)
    File.mkdir_p!(lock_path)
    File.write!(Path.join(lock_path, "owner.json"), "")

    assert {:error, {:project_already_running, owner}} =
             trap_start_link(fn ->
               ProjectLock.start_link(
                 project_lock_opts(
                   name: Module.concat(__MODULE__, :BrokenProject),
                   project_slug: "broken-project",
                   lock_root: lock_root
                 )
               )
             end)

    assert owner.project_slug == "broken-project"
    assert owner.lock_path == lock_path
    assert owner.details =~ "owner metadata is unavailable"
  end

  test "reports lock-root creation failures explicitly", %{lock_root: lock_root} do
    blocked_parent = Path.join(lock_root, "not-a-directory")
    bad_root = Path.join(blocked_parent, "child")
    expected_lock_path = ProjectLock.lock_path_for_test("bad-root", bad_root)
    File.write!(blocked_parent, "file")

    assert {:error, {:project_lock_unavailable, "bad-root", ^expected_lock_path, :enotdir}} =
             trap_start_link(fn ->
               ProjectLock.start_link(
                 project_lock_opts(
                   name: Module.concat(__MODULE__, :BadRoot),
                   project_slug: "bad-root",
                   lock_root: bad_root
                 )
               )
             end)
  end

  test "formats duplicate start messages with optional details" do
    message =
      ProjectLock.duplicate_start_message(%{
        project_slug: "project-detail",
        hostname: "host-detail",
        details: "owner metadata is unavailable"
      })

    assert message ==
             "another Symphony process is already serving Linear project project-detail on host-detail; owner metadata is unavailable"
  end

  test "start_link/0 follows the current workflow config" do
    with_memory_workflow(fn ->
      assert {:ok, pid} = ProjectLock.start_link()
      assert %{lock_path: nil, metadata_path: nil, owner: nil} = :sys.get_state(pid)
      GenServer.stop(pid)
    end)
  end

  test "returns ok for terminate fallback clauses" do
    assert :ok = ProjectLock.terminate(:normal, :unknown)
    assert :ok = ProjectLock.terminate(:normal, %{lock_path: "/tmp/lock", metadata_path: nil, owner: nil})
  end

  test "cleans up the lock directory when owner metadata cannot be encoded", %{lock_root: lock_root} do
    assert {:error, {:project_lock_unavailable, "encode-error", lock_path, %Protocol.UndefinedError{}}} =
             trap_start_link(fn ->
               ProjectLock.start_link(
                 project_lock_opts(
                   name: Module.concat(__MODULE__, :EncodeError),
                   project_slug: "encode-error",
                   lock_root: lock_root,
                   workflow_path: {:not, "json"}
                 )
               )
             end)

    refute File.exists?(lock_path)
  end

  test "surfaces lock-path creation failures after the root already exists", %{lock_root: lock_root} do
    File.chmod!(lock_root, 0o500)

    on_exit(fn ->
      File.chmod!(lock_root, 0o700)
    end)

    assert {:error, {:project_lock_unavailable, "mkdir-failure", _lock_path, reason}} =
             trap_start_link(fn ->
               ProjectLock.start_link(
                 project_lock_opts(
                   name: Module.concat(__MODULE__, :MkdirFailure),
                   project_slug: "mkdir-failure",
                   lock_root: lock_root
                 )
               )
             end)

    assert reason in [:eacces, :eperm]
  end

  test "surfaces stale-lock cleanup failures when the lock cannot be removed", %{lock_root: lock_root} do
    lock_path = ProjectLock.lock_path_for_test("stale-remove-failure", lock_root)
    File.mkdir_p!(lock_path)

    File.write!(
      Path.join(lock_path, "owner.json"),
      Jason.encode!(%{
        instance_id: "stale-owner",
        project_slug: "stale-remove-failure",
        hostname: "old-host",
        pid: 99_999,
        workflow_path: "/tmp/stale-workflow.md",
        cwd: "/tmp/stale-workspace",
        started_at: "2026-02-27T22:30:00Z"
      })
    )

    File.chmod!(lock_root, 0o500)

    on_exit(fn ->
      File.chmod!(lock_root, 0o700)
    end)

    assert {:error, {:project_lock_unavailable, "stale-remove-failure", ^lock_path, reason}} =
             trap_start_link(fn ->
               ProjectLock.start_link(
                 project_lock_opts(
                   name: Module.concat(__MODULE__, :StaleRemoveFailure),
                   project_slug: "stale-remove-failure",
                   lock_root: lock_root,
                   pid_alive?: fn _pid -> false end
                 )
               )
             end)

    assert reason in [:eacces, :eperm]
  end

  test "logs a warning when releasing the lock cannot remove the directory", %{lock_root: lock_root} do
    lock_path = ProjectLock.lock_path_for_test("release-warning", lock_root)
    metadata_path = Path.join(lock_path, "owner.json")

    owner = %{
      instance_id: "owner-release-warning",
      project_slug: "release-warning",
      hostname: "test-host",
      pid: 12_345,
      workflow_path: "/tmp/WORKFLOW.md",
      cwd: "/tmp/workspace",
      started_at: "2026-02-27T22:30:00Z",
      lock_path: lock_path
    }

    File.mkdir_p!(lock_path)
    File.write!(metadata_path, Jason.encode!(owner))
    File.chmod!(lock_root, 0o500)

    on_exit(fn ->
      File.chmod!(lock_root, 0o700)
    end)

    log =
      capture_log(fn ->
        assert :ok =
                 ProjectLock.terminate(:normal, %{
                   lock_path: lock_path,
                   metadata_path: metadata_path,
                   owner: owner
                 })
      end)

    assert log =~ "Failed to release project lock #{lock_path}"
  end

  test "treats lock owners without a pid as active and omits pid details", %{lock_root: lock_root} do
    lock_path = ProjectLock.lock_path_for_test("owner-without-pid", lock_root)
    File.mkdir_p!(lock_path)

    File.write!(
      Path.join(lock_path, "owner.json"),
      Jason.encode!(%{
        instance_id: "owner-without-pid",
        project_slug: "owner-without-pid",
        hostname: "no-pid-host",
        workflow_path: "/tmp/no-pid-workflow.md",
        cwd: "/tmp/no-pid-workspace",
        started_at: "2026-02-27T22:30:00Z"
      })
    )

    assert {:error, {:project_already_running, owner}} =
             trap_start_link(fn ->
               ProjectLock.start_link(
                 project_lock_opts(
                   name: Module.concat(__MODULE__, :OwnerWithoutPid),
                   project_slug: "owner-without-pid",
                   lock_root: lock_root
                 )
               )
             end)

    assert owner.pid == nil
    refute ProjectLock.duplicate_start_message(owner) =~ "(pid "
  end

  test "normalizes invalid configured pids to nil in lock state", %{lock_root: lock_root} do
    assert {:ok, pid} =
             ProjectLock.start_link(
               project_lock_opts(
                 name: Module.concat(__MODULE__, :InvalidPid),
                 project_slug: "invalid-pid",
                 lock_root: lock_root,
                 os_pid: "not-a-pid"
               )
             )

    assert %{owner: %{pid: nil}} = :sys.get_state(pid)
    GenServer.stop(pid)
  end

  test "normalizes empty project-slug prefixes to a generic lock directory name", %{lock_root: lock_root} do
    basename =
      ProjectLock.lock_path_for_test("!!!", lock_root)
      |> Path.basename()

    assert String.starts_with?(basename, "project-")
  end

  test "hostname_for_test falls back when hostname lookup fails" do
    assert ProjectLock.hostname_for_test(fn -> :error end) == "unknown-host"
  end

  test "os_pid_alive_for_test handles missing kill binary, success, failure, and invalid input" do
    assert ProjectLock.os_pid_alive_for_test(12_345, fn "kill" -> nil end, fn _, _, _ -> {"", 0} end) == :unknown

    assert ProjectLock.os_pid_alive_for_test(
             12_345,
             fn "kill" -> "/usr/bin/kill" end,
             fn "/usr/bin/kill", ["-0", "12345"], stderr_to_stdout: true -> {"", 0} end
           ) == true

    assert ProjectLock.os_pid_alive_for_test(
             12_345,
             fn "kill" -> "/usr/bin/kill" end,
             fn "/usr/bin/kill", ["-0", "12345"], stderr_to_stdout: true -> {"", 1} end
           ) == false

    assert ProjectLock.os_pid_alive_for_test("invalid") == :unknown
  end

  defp project_lock_opts(overrides) do
    Keyword.merge(
      [
        tracker_kind: "linear",
        workflow_path: "/tmp/WORKFLOW.md",
        cwd: "/tmp/workspace",
        hostname: "test-host",
        started_at: "2026-02-27T22:30:00Z",
        pid_alive?: fn _pid -> false end
      ],
      overrides
    )
  end

  defp temporary_child_spec(id, opts) do
    %{
      id: id,
      start: {ProjectLock, :start_link, [opts]},
      restart: :temporary
    }
  end

  defp trap_start_link(fun) do
    previous_flag = Process.flag(:trap_exit, true)

    try do
      fun.()
    after
      Process.flag(:trap_exit, previous_flag)
    end
  end

  defp with_memory_workflow(fun) do
    original_path = Workflow.workflow_file_path()

    workflow_root =
      Path.join(
        System.tmp_dir!(),
        "project-lock-workflow-#{System.unique_integer([:positive])}"
      )

    workflow_path = Path.join(workflow_root, "WORKFLOW.md")

    File.mkdir_p!(workflow_root)

    File.write!(
      workflow_path,
      """
      ---
      tracker:
        kind: memory
      ---
      Test prompt
      """
    )

    Workflow.set_workflow_file_path(workflow_path)

    try do
      fun.()
    after
      Workflow.set_workflow_file_path(original_path)
      File.rm_rf(workflow_root)
    end
  end
end
