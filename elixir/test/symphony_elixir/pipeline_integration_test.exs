defmodule SymphonyElixir.PipelineIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Skills
  alias SymphonyElixir.Config
  alias SymphonyElixir.Pipeline
  alias SymphonyElixir.Pipeline.Store
  alias SymphonyElixir.PipelineIntegrationTest.HoldingAgent

  test "pipeline reconciliation fetches all task issues in one tracker lookup" do
    first_issue = issue("octo/app#20", 20)
    first_issue = %{first_issue | native_ref: Map.merge(first_issue.native_ref, %{project_id: "PVT_test", project_item_id: "PVTI_20", issue_number: 20})}
    issues = [first_issue, issue("octo/app#21", 21)]
    table = start_board(issues, %{})
    pipeline_database!(table)

    Enum.each(issues, fn issue ->
      assert {:ok, task, "build"} = Pipeline.prepare(issue)
      assert task["execution_identity"] == Issue.execution_identity(issue)
    end)

    assert :ok = Pipeline.reconcile()
    assert [{:fetch_issues_by_ids_calls, 1}] = :ets.lookup(table, :fetch_issues_by_ids_calls)
    assert [{{:fetch_issues_by_ids_call, 1}, ids}] = :ets.lookup(table, {:fetch_issues_by_ids_call, 1})
    assert MapSet.new(ids) == MapSet.new(Enum.map(issues, & &1.id))
  end

  test "qa-labeled issues start in QA while feature issues keep Build, QA, and Review" do
    qa_issue = %{issue("octo/app#60", 60) | labels: ["qa"]}
    feature_issue = %{issue("octo/app#61", 61) | labels: ["feature"]}

    table =
      start_board([qa_issue, feature_issue], %{
        qa_issue.id => %{qa: [qa("qa-sha")], review: [review("qa-sha")]},
        feature_issue.id => %{build: [build("feature-sha", feature_issue.id)], qa: [qa("feature-sha")], review: [review("feature-sha")]}
      })

    path = pipeline_database!(table, retry_backoff_ms: 300_000)
    workspace = ensure_test_workspace!(qa_issue)
    {qa_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)
    qa_sha = String.trim(qa_sha)

    :ets.insert(table, {{:remote_sha, qa_issue.id}, qa_sha})

    :ets.insert(
      table,
      {{:pull_request, qa_issue.id}, %{number: 160, branch: qa_issue.branch_name, base: "main", sha: qa_sha, draft: true, merged: false, body: "", url: "https://github.com/octo/app/pull/160"}}
    )

    orchestrator = start_orchestrator()

    assert await(fn ->
             project_state(table, qa_issue.id) == "Human Review" and
               project_state(table, feature_issue.id) == "Human Review"
           end)

    assert report_phases(table, qa_issue.id) == [:qa, :review]
    assert agent_calls(table, qa_issue.id, :build) == 0
    assert report_phases(table, feature_issue.id) == [:build, :qa, :review]

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "a slow skill preflight does not stop the orchestrator responding" do
    issue = issue("octo/app#17", 17)
    table = start_board([issue], %{})
    pipeline_database!(table)
    orchestrator = start_orchestrator(__MODULE__.SlowSkillPreflightAgent)

    assert await(fn -> lookup(table, :preflight_pid) != nil end)
    preflight = lookup(table, :preflight_pid)
    snapshot = Task.async(fn -> GenServer.call(orchestrator, :snapshot, 2_000) end)
    result = Task.yield(snapshot, 100)
    send(preflight, :continue)
    assert {:ok, _} = result
    stop_orchestrator(orchestrator)
  end

  test "a human status change during skill preflight prevents the stale result from claiming" do
    issue = issue("octo/app#16", 16)
    table = start_board([issue], %{})
    pipeline_database!(table, retry_backoff_ms: 300_000)
    orchestrator = start_orchestrator(__MODULE__.SlowSkillPreflightAgent)

    assert await(fn -> lookup(table, :preflight_pid) != nil end)
    preflight = lookup(table, :preflight_pid)
    set_project_state(table, issue.id, "Building")
    assert await(fn -> get_in(:sys.get_state(orchestrator), [Access.key(:running), issue.id, :issue, Access.key(:state)]) == "Building" end)
    send(preflight, :continue)
    assert await(fn -> not Map.has_key?(:sys.get_state(orchestrator).running, issue.id) end)
    assert {:ok, task} = Store.get_task(issue.id)
    refute get_in(task, ["skill_readiness", "status"]) == "failed"
    stop_orchestrator(orchestrator)
  end

  test "a workspace preflight completes safely after the issue leaves active states" do
    issue = issue("octo/app#15", 15)
    table = start_board([issue], %{})
    pipeline_database!(table, retry_backoff_ms: 300_000)
    orchestrator = start_orchestrator(__MODULE__.SlowSkillPreflightAgent)

    assert await(fn -> lookup(table, :preflight_pid) != nil end)
    preflight = lookup(table, :preflight_pid)
    set_project_state(table, issue.id, "Backlog")
    Process.sleep(100)
    assert Process.alive?(preflight)
    send(preflight, :continue)
    assert await(fn -> not Map.has_key?(:sys.get_state(orchestrator).running, issue.id) end)
    assert {:ok, task} = Store.get_task(issue.id)
    refute get_in(task, ["skill_readiness", "status"]) == "failed"
    stop_orchestrator(orchestrator)
  end

  test "persists the phase skill snapshot across runtime restarts" do
    issue = issue("octo/app#19", 19)
    table = start_board([issue], %{})
    pipeline_database!(table)

    assert {:ok, task, "build"} = Pipeline.prepare(issue)
    expected_skills = task["effective_config"]["skills"]
    assert [%{"name" => "ponytail", "version" => "v5.3.2"}] = expected_skills["build"]

    set_project_state(table, issue.id, "Backlog")

    for _ <- 1..2 do
      orchestrator = start_orchestrator()
      Process.sleep(30)
      stop_orchestrator(orchestrator)
    end

    assert {:ok, persisted} = Store.get_task(issue.id)
    assert persisted["effective_config"]["skills"] == expected_skills
  end

  test "a skill readiness mismatch leaves the Project item unclaimed" do
    issue = %{issue("octo/app#18", 18) | native_ref: nil}
    table = start_board([issue], %{})
    pipeline_database!(table)
    workspace = Path.join(Config.local_workspace_root(), Workspace.workspace_key(issue))
    skill_dir = Path.join([workspace, ".agents", "skills", "ponytail"])
    source = Path.expand("../../..", __DIR__) |> Path.join(".agents/skills/ponytail")
    File.mkdir_p!(Path.dirname(skill_dir))
    File.cp_r!(source, skill_dir)
    skill_path = Path.join(skill_dir, "SKILL.md")
    File.write!(skill_path, File.read!(skill_path) <> "\nchanged\n")
    on_exit(fn -> File.rm_rf!(workspace) end)

    orchestrator = start_orchestrator(SymphonyElixir.PipelineIntegrationTest.RealSkillPreflightAgent)

    assert await(fn -> match?({:ok, %{"skill_readiness" => %{"status" => "failed"}}}, Store.get_task(issue.id)) end)

    assert project_state(table, issue.id) == "Ready"
    assert lookup(table, {:agent_calls, issue.id, :build}) == nil
    assert {:ok, %{"effective_config" => %{"skills" => %{"build" => [%{"version" => "v5.3.2"}]}}}} = Store.get_task(issue.id)
    assert {:ok, %{"skill_readiness" => %{"reason" => reason, "next_step" => next_step}}} = Store.get_task(issue.id)
    assert reason =~ "ponytail"
    assert next_step =~ "v5.3.2"
    stop_orchestrator(orchestrator)
  end

  test "workspace skill readiness verifies the pinned checksum list" do
    issue = %Issue{labels: []}
    repository = Path.expand("../../..", __DIR__)
    snapshot = Skills.snapshot_for_phase(issue, :build)

    assert :ok = Workspace.verify_skill_snapshot(repository, snapshot, nil)
  end

  test "a Review worker survives polls between its handoffs and finalizes a confirmed merge" do
    issue = issue("octo/app#90", 90)
    table = start_board([issue], %{issue.id => %{build: [build("sha", issue.id)], qa: [qa("sha")], review: [review("sha")]}})
    pipeline_database!(table)
    name = Module.concat(__MODULE__, "PausedReview#{System.unique_integer([:positive])}")
    {:ok, orchestrator} = Orchestrator.start_link(name: name, agent_runner: __MODULE__.PausedReviewAgent)

    assert await(fn -> lookup(table, {:paused_review, issue.id}) != nil end)
    worker = lookup(table, {:paused_review, issue.id})
    assert project_state(table, issue.id) == "Human Review"
    refresh!(name, table)
    assert Process.alive?(worker)
    assert {:ok, %{"status" => "review", "phase" => "review"}} = Store.get_task(issue.id)

    set_pull_request_merged(table, issue.id, true)
    set_github_issue_state(table, issue.id, "closed")
    :ets.insert(table, {:fail_pr_reads, 2})
    refresh!(name, table)
    assert Process.alive?(worker)
    assert {:ok, %{"status" => "review", "phase" => "review"}} = Store.get_task(issue.id)
    send(worker, :finish_review)
    assert await(fn -> project_state(table, issue.id) == "Done" end)
    assert await(fn -> match?({:ok, %{"status" => "done"}}, Store.get_task(issue.id)) end)
    stop_orchestrator(orchestrator)
  end

  test "a stale merge requeues Build and repeats QA and Review after restart" do
    issue = issue("octo/app#92", 92)
    table = start_board([issue], %{issue.id => %{build: [build("updated", issue.id)], qa: [qa("updated")], review: [review("updated")]}})
    pipeline_database!(table, retry_backoff_ms: 300_000)

    assert {:ok, task, "build"} = Pipeline.prepare(issue)
    old = task |> Map.put("phase", "review") |> Map.put("status", "review") |> Map.put("current_sha", "old-sha") |> Map.put("stale_merge_retry", true)
    assert :ok = Store.save_task(old)
    assert :ok = Pipeline.reconcile([issue.id])
    assert :ok = Pipeline.reconcile()
    assert {:ok, %{"status" => "review", "stale_merge_retry" => true}} = Store.get_task(issue.id)

    orchestrator = start_orchestrator()
    assert await(fn -> project_state(table, issue.id) == "Human Review" end), inspect({project_state(table, issue.id), Store.get_task(issue.id), report_phases(table, issue.id)})
    assert report_phases(table, issue.id) == [:build, :qa, :review]
    assert {:ok, %{"generation" => 2, "current_sha" => sha}} = Store.get_task(issue.id)
    refute sha == "old-sha"
    stop_orchestrator(orchestrator)
  end

  test "a stale merge also returns a QA-labelled issue to Build" do
    issue = issue("octo/app#93", 93)
    table = start_board([issue], %{})
    pipeline_database!(table)
    assert {:ok, task, "build"} = Pipeline.prepare(issue)
    task = task |> Map.put("phase", "review") |> Map.put("status", "human_review") |> Map.put("stale_merge_retry", true)
    assert :ok = Store.save_task(task)

    assert {:ok, %{"phase" => "build", "current_sha" => nil}, "build"} = Pipeline.prepare(%{issue | labels: ["qa"]})
  end

  test "a lost Review handoff leaves the task in Human Review after restart" do
    issue = issue("octo/app#91", 91)
    table = start_board([issue], %{issue.id => %{build: [build("sha", issue.id)], qa: [qa("sha")], review: [review("sha")]}})
    pipeline_database!(table)
    orchestrator = start_orchestrator(__MODULE__.PausedReviewAgent)

    assert await(fn -> lookup(table, {:paused_review, issue.id}) != nil end)
    assert project_state(table, issue.id) == "Human Review"
    stop_orchestrator(orchestrator)

    orchestrator = start_orchestrator()
    assert await(fn -> match?({:ok, %{"status" => "human_review"}}, Store.get_task(issue.id)) end)
    assert project_state(table, issue.id) == "Human Review"
    refute pull_request(table, issue.id).merged
    stop_orchestrator(orchestrator)
  end

  test "running Project work survives one missing refresh and stops after two consecutive omissions" do
    issue = issue("octo/app#46", 46)
    issue = %{issue | state: "Building", native_ref: Map.put(issue.native_ref, :project_status, "Building")}
    table = start_board([issue], %{})
    database_path = pipeline_database!(table, poll_interval_ms: 60_000)
    orchestrator_name = Module.concat(__MODULE__, "MissingRefresh#{System.unique_integer([:positive])}")

    {:ok, orchestrator_pid} =
      Orchestrator.start_link(name: orchestrator_name, agent_runner: HoldingAgent)

    on_exit(fn -> stop_orchestrator(orchestrator_pid) end)

    assert await(fn -> lookup(table, {:held_agent_pid, issue.id}) != nil end)
    agent_pid = lookup(table, {:held_agent_pid, issue.id})
    assert await(fn -> Map.get(:sys.get_state(orchestrator_name).running[issue.id] || %{}, :workspace_path) != nil end)
    workspace = :sys.get_state(orchestrator_name).running[issue.id].workspace_path

    session_id = "thread-live-turn-live"
    send(orchestrator_pid, {:codex_worker_update, issue.id, %{event: :session_started, session_id: session_id, timestamp: DateTime.utc_now()}})
    assert await(fn -> :sys.get_state(orchestrator_name).running[issue.id].session_id == session_id end)

    assert File.exists?(database_path)
    assert {:ok, %{"status" => "building"}} = Store.get_task(issue.id)
    assert :sys.get_state(orchestrator_name).running[issue.id].pid == agent_pid
    assert Process.alive?(agent_pid)
    assert MapSet.member?(:sys.get_state(orchestrator_name).claimed, issue.id)
    assert File.dir?(workspace)

    :ets.insert(table, {:fetch_issues_by_ids_responses, [{:ok, [issue]}, {:ok, []}]})
    first_omission_log = capture_log(fn -> refresh!(orchestrator_name, table) end)

    assert first_omission_log =~ issue.identifier
    assert first_omission_log =~ "session_id=#{session_id}"
    assert first_omission_log =~ "consecutive_absences=1"
    assert first_omission_log =~ "normalized_issue_count=0"
    assert_running_agent(orchestrator_name, issue, agent_pid, workspace, 1)
    assert project_state(table, issue.id) == "Building"

    :ets.insert(table, {:fetch_issues_by_ids_responses, [{:ok, [issue]}, {:ok, [issue]}]})
    recovery_log = capture_log(fn -> refresh!(orchestrator_name, table) end)

    assert recovery_log =~ "Issue recovered after successful running-state refresh"
    assert recovery_log =~ "session_id=#{session_id}"
    assert_running_agent(orchestrator_name, issue, agent_pid, workspace, 0)

    :ets.insert(table, {:fetch_issues_by_ids_responses, [{:ok, [issue]}, {:error, :econnreset}]})
    refresh!(orchestrator_name, table)
    assert_running_agent(orchestrator_name, issue, agent_pid, workspace, 0)

    :ets.insert(table, {:fetch_issues_by_ids_responses, [{:ok, [issue]}, {:ok, []}]})
    refresh!(orchestrator_name, table)
    assert_running_agent(orchestrator_name, issue, agent_pid, workspace, 1)

    :ets.insert(table, {:hide_state_listing, true})
    :ets.insert(table, {:fetch_issues_by_ids_responses, [{:ok, [issue]}, {:ok, []}]})
    confirmed_omission_log = capture_log(fn -> refresh!(orchestrator_name, table) end)

    assert confirmed_omission_log =~ "consecutive_absences=2"
    assert confirmed_omission_log =~ "session_id=#{session_id}"
    assert confirmed_omission_log =~ "normalized_issue_count=0"
    assert await(fn -> not Process.alive?(agent_pid) end)

    state = :sys.get_state(orchestrator_name)
    refute Map.has_key?(state.running, issue.id)
    refute MapSet.member?(state.claimed, issue.id)
    assert map_size(state.running) == 0
    assert lookup(table, {:agent_calls, issue.id, :build}) == 1
    assert File.dir?(workspace)
    assert project_state(table, issue.id) == "Building"

    stop_orchestrator(orchestrator_pid)
  end

  test "a qa-labeled task never enters Build after QA finds a defect" do
    issue = %{issue("octo/app#64", 64) | labels: ["qa"]}
    result = %{qa("qa-sha") | "outcome" => "changes_requested", "summary" => "A check failed."}
    table = start_board([issue], %{issue.id => %{qa: [result]}})
    pipeline_database!(table, retry_backoff_ms: 300_000)
    workspace = ensure_test_workspace!(issue)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)
    sha = String.trim(sha)
    :ets.insert(table, {{:remote_sha, issue.id}, sha})

    :ets.insert(
      table,
      {{:pull_request, issue.id}, %{number: 164, branch: issue.branch_name, base: "main", sha: sha, draft: true, merged: false, body: "", url: "https://github.com/octo/app/pull/164"}}
    )

    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Blocked" end)
    assert await(fn -> match?({:ok, %{"status" => "blocked"}}, Store.get_task(issue.id)) end)
    assert agent_calls(table, issue.id, :build) == 0
    stop_orchestrator(orchestrator)
  end

  test "a blocked qa-labeled task waits for a valid PR and resumes QA without Build" do
    issue = %{issue("octo/app#65", 65) | labels: ["qa"]}
    table = start_board([issue], %{})
    pipeline_database!(table)
    assert {:ok, task, "qa"} = Pipeline.prepare(issue)
    assert :ok = Store.save_task(Map.put(task, "status", "blocked"))
    assert {:ok, %{"current_sha" => nil, "status" => "qa"} = retry, "qa"} = Pipeline.prepare(issue)
    assert :ok = Store.save_task(Map.put(retry, "status", "blocked"))

    :ets.insert(table, {{:pull_request, issue.id}, %{number: 165, branch: issue.branch_name, base: "main", sha: "new-qa-sha", draft: true, merged: false}})
    assert {:ok, %{"current_sha" => "new-qa-sha", "status" => "qa"}, "qa"} = Pipeline.prepare(issue)
  end

  test "a qa-labeled task without a PR records a diagnostic in the Project" do
    issue = %{issue("octo/app#67", 67) | labels: ["qa"]}
    table = start_board([issue], %{})
    pipeline_database!(table, retry_backoff_ms: 300_000)
    assert {:ok, task, "qa"} = Pipeline.prepare(issue)
    assert :ok = Store.save_task(Map.put(task, "status", "blocked"))
    orchestrator = start_orchestrator(__MODULE__.DiagnosticAgent)
    assert await(fn -> project_state(table, issue.id) == "Blocked" end)
    assert agent_calls(table, issue.id, :build) == 0
    stop_orchestrator(orchestrator)
  end

  test "a qa-labeled task returned from Human Review resumes QA in a new generation" do
    issue = %{issue("octo/app#66", 66) | labels: ["qa"]}
    table = start_board([issue], %{})
    pipeline_database!(table)
    :ets.insert(table, {{:pull_request, issue.id}, %{number: 166, branch: issue.branch_name, base: "main", sha: "qa-sha", draft: false, merged: false}})
    assert {:ok, task, "qa"} = Pipeline.prepare(issue)
    assert :ok = Store.save_task(Map.put(task, "status", "human_review"))
    assert {:ok, %{"generation" => 2, "status" => "qa"}, "qa"} = Pipeline.prepare(issue)
  end

  test "direct QA resumes after a restart before the Project claim" do
    issue = %{issue("octo/app#62", 62) | labels: ["qa"]}
    table = start_board([issue], %{})
    pipeline_database!(table)
    :ets.insert(table, {{:pull_request, issue.id}, %{number: 162, branch: issue.branch_name, base: "main", sha: "qa-sha", draft: true, merged: false}})

    assert {:ok, %{"status" => "qa"}, "qa"} = Pipeline.prepare(issue)
    assert :ok = Pipeline.reconcile()
    assert {:ok, %{"status" => "qa"} = task, "qa"} = Pipeline.prepare(issue)

    assert :ok = Store.save_task(Map.delete(task, "direct_qa"))
    set_project_state(table, issue.id, "Building")
    assert :ok = Pipeline.reconcile()
    assert {:ok, %{"status" => "building", "phase" => "build"}} = Store.get_task(issue.id)
  end

  test "an uncertain direct QA claim waits for an explicit Blocked to Ready transition" do
    issue = %{issue("octo/app#63", 63) | labels: ["qa"]}
    table = start_board([issue], %{})
    pipeline_database!(table)
    :ets.insert(table, {{:pull_request, issue.id}, %{number: 163, branch: issue.branch_name, base: "main", sha: "qa-sha", draft: true, merged: false}})

    assert {:ok, task, "qa"} = Pipeline.prepare(issue)
    assert :ok = Store.save_task(Map.put(task, "qa_claim_pending", true))
    assert :ok = Pipeline.reconcile()
    assert :ignore = Pipeline.prepare(issue)
    assert {:ok, %{"status" => "blocked"}} = Store.get_task(issue.id)

    set_project_state(table, issue.id, "Blocked")
    assert :ok = Pipeline.reconcile()
    set_project_state(table, issue.id, "Ready")
    assert {:ok, %{"status" => "qa"}, "qa"} = Pipeline.prepare(issue)
  end

  test "the Project's QA state overrides a Build checkpoint" do
    issue = issue("octo/app#22", 22)
    issue = %{issue | state: "QA", native_ref: Map.put(issue.native_ref, :project_status, "QA")}
    table = start_board([issue], %{})
    pipeline_database!(table)

    task = %{
      "issue_id" => issue.id,
      "repository" => "octo/app",
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "required_checks" => ["true"],
      "generation" => 1,
      "phase" => "build",
      "status" => "building",
      "attempts" => %{},
      "prior_findings" => [],
      "current_sha" => nil,
      "pr_number" => nil
    }

    assert :ok = Store.save_task(task)
    assert {:ok, %{"status" => "qa", "phase" => "qa"}, "qa"} = Pipeline.prepare(issue)
    assert :ok = Store.save_task(task)
    assert :ok = Pipeline.reconcile()

    assert {:ok, %{"status" => "qa", "phase" => "qa"}} = Store.get_task(issue.id)
    assert project_state(table, issue.id) == "QA"
  end

  test "QA on the board resumes a locally blocked Build checkpoint using the current PR" do
    issue = issue("octo/app#23", 23)
    issue = %{issue | state: "QA", native_ref: Map.put(issue.native_ref, :project_status, "QA")}
    table = start_board([issue], %{})
    pipeline_database!(table)
    :ets.insert(table, {{:pull_request, issue.id}, %{number: 123, branch: issue.branch_name, base: "main", sha: "current-sha", draft: true, merged: false}})

    :ets.insert(
      table,
      {{:remote_reports, issue.id},
       [%{"generation" => 1, "phase" => "build", "attempt" => 1, "report" => %{"outcome" => "ready", "sha" => "current-sha", "branch" => issue.branch_name, "base_branch" => "main"}}]}
    )

    assert :ok =
             Store.save_task(%{
               "issue_id" => issue.id,
               "repository" => "octo/app",
               "branch" => issue.branch_name,
               "base_branch" => "main",
               "required_checks" => ["true"],
               "generation" => 1,
               "phase" => "build",
               "status" => "blocked",
               "blocked_reason" => "checkpoint mismatch",
               "attempts" => %{},
               "prior_findings" => [],
               "current_sha" => nil,
               "pr_number" => nil
             })

    assert :ok = Pipeline.reconcile()
    assert {:ok, %{"status" => "qa", "phase" => "qa", "current_sha" => "current-sha", "pr_number" => 123}, "qa"} = Pipeline.prepare(issue)
    assert project_state(table, issue.id) == "QA"
  end

  test "a QA item can resume without a local checkpoint" do
    issue = issue("octo/app#24", 24)
    issue = %{issue | state: "QA", native_ref: Map.put(issue.native_ref, :project_status, "QA")}
    table = start_board([issue], %{})
    pipeline_database!(table)
    :ets.insert(table, {{:pull_request, issue.id}, %{number: 124, branch: issue.branch_name, base: "main", sha: "current-sha", draft: true, merged: false}})

    :ets.insert(
      table,
      {{:remote_reports, issue.id},
       [
         %{"generation" => 3, "phase" => "build", "attempt" => 4, "report" => %{"outcome" => "ready", "sha" => "current-sha", "branch" => issue.branch_name, "base_branch" => "main"}},
         %{"generation" => 3, "phase" => "qa", "attempt" => 7, "report" => %{"outcome" => "changes_requested", "sha" => "current-sha"}}
       ]}
    )

    assert {:ok, %{"phase" => "qa", "current_sha" => "current-sha", "generation" => 3, "attempts" => %{"qa" => 7, "build" => 4}}, "qa"} = Pipeline.prepare(issue)
  end

  test "reconciliation leaves a running phase alone during its handoff" do
    issue = issue("octo/app#25", 25)
    table = start_board([issue], %{})
    pipeline_database!(table)
    assert {:ok, task, "build"} = Pipeline.prepare(issue)
    set_project_state(table, issue.id, "QA")

    assert :ok = Pipeline.reconcile([issue.id])
    assert {:ok, ^task} = Store.get_task(issue.id)
  end

  test "a changed PR invalidates saved host checks when the board moves to QA" do
    issue = issue("octo/app#26", 26)
    table = start_board([issue], %{})
    pipeline_database!(table)
    assert {:ok, task, "build"} = Pipeline.prepare(issue)
    assert :ok = Store.save_task(Map.merge(task, %{"current_sha" => "old", "host_checks" => [%{"status" => "passed"}]}))
    :ets.insert(table, {{:pull_request, issue.id}, %{number: 126, branch: issue.branch_name, base: "main", sha: "new", draft: true, merged: false}})
    qa_issue = %{issue | state: "QA", native_ref: Map.put(issue.native_ref, :project_status, "QA")}

    assert {:ok, task, "qa"} = Pipeline.prepare(qa_issue)
    assert task["current_sha"] == nil
    assert task["host_checks"] == []
  end

  test "moving from QA to Building clears the accepted SHA before Build resumes" do
    issue = issue("octo/app#27", 27)
    table = start_board([issue], %{})
    pipeline_database!(table)
    assert {:ok, task, "build"} = Pipeline.prepare(issue)
    assert :ok = Store.save_task(Map.merge(task, %{"phase" => "qa", "status" => "qa", "current_sha" => "old", "host_checks" => [%{"status" => "passed"}]}))
    building = %{issue | state: "Building", native_ref: Map.put(issue.native_ref, :project_status, "Building")}

    assert {:ok, task, "build"} = Pipeline.prepare(building)
    assert task["current_sha"] == nil
    refute Map.has_key?(task, "host_checks")
  end

  test "Review without a QA report does not invent check evidence" do
    issue = issue("octo/app#28", 28)
    table = start_board([issue], %{})
    pipeline_database!(table)
    assert {:ok, task, "build"} = Pipeline.prepare(issue)
    :ets.insert(table, {{:pull_request, issue.id}, %{number: 128, branch: issue.branch_name, base: "main", sha: "sha", draft: true, merged: false}})

    :ets.insert(
      table,
      {{:remote_reports, issue.id},
       [%{"generation" => 1, "phase" => "build", "attempt" => 1, "report" => %{"outcome" => "ready", "sha" => "sha", "branch" => issue.branch_name, "base_branch" => "main"}}]}
    )

    review = %{issue | state: "Review", native_ref: Map.put(issue.native_ref, :project_status, "Review")}

    assert {:ok, recovered, "review"} = Pipeline.prepare(review)
    assert recovered["host_checks"] == []
    assert task["generation"] == recovered["generation"]
  end

  test "recovery processes findings in the order they were published" do
    issue = issue("octo/app#29", 29)
    table = start_board([issue], %{})
    pipeline_database!(table)
    assert {:ok, _, "build"} = Pipeline.prepare(issue)
    :ets.insert(table, {{:pull_request, issue.id}, %{number: 129, branch: issue.branch_name, base: "main", sha: "sha", draft: true, merged: false}})
    finding = %{"id" => "x", "criterion" => "criterion", "reproduction" => "steps"}

    reports = [
      %{"generation" => 1, "phase" => "qa", "attempt" => 1, "report" => %{"findings" => [finding]}},
      %{"generation" => 1, "phase" => "review", "attempt" => 1, "report" => %{"resolutions" => ["x"]}},
      %{"generation" => 1, "phase" => "qa", "attempt" => 2, "report" => %{"findings" => [finding]}}
    ]

    :ets.insert(table, {{:remote_reports, issue.id}, reports})
    qa = %{issue | state: "QA", native_ref: Map.put(issue.native_ref, :project_status, "QA")}

    assert {:ok, recovered, "qa"} = Pipeline.prepare(qa)
    assert recovered["prior_findings"] == [finding]
  end

  test "report locale uses Spanish only for Spanish issue descriptions" do
    for {description, locale} <- [
          {"Implementar soporte para nuevas salas", :es},
          {"Permitir crear salas privadas", :es},
          {"Actualizar modulo principal", :es},
          {"Add support for private rooms", :en},
          {"Implement login for usuarios", :en},
          {"Créer des salles privées", :en},
          {"Unterstützung für private Räume", :en},
          {"Adicionar suporte para salas privadas na aplicação", :en}
        ] do
      assert Pipeline.report_locale(%{issue("octo/app#42", 42) | description: description}) == locale
    end
  end

  test "Build finish recovers the validated PR body from successful remote handoff evidence" do
    issue = issue("octo/app#56", 56)
    table = start_board([issue], %{})
    pipeline_database!(table)
    sha = String.duplicate("a", 40)
    body = build(sha, issue.id)["pull_request_body"]

    task = %{
      "issue_id" => issue.id,
      "generation" => 1,
      "phase" => "build",
      "attempts" => %{"build" => 1},
      "status" => "building",
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "current_sha" => sha
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue.id, 1, "build", 1)
    :ets.insert(table, {{:remote_sha, issue.id}, sha})

    report =
      build(sha, issue.id)
      |> Map.delete("pull_request_body")
      |> Map.put("_remote_evidence", [
        %{
          "outcome" => "ready",
          "issue" => %{"id" => issue.id},
          "comment" => %{"id" => "comment-56", "url" => "https://github.com/octo/app/issues/56#issuecomment-1"},
          "project_item" => %{"id" => "item-56", "status" => "QA"},
          "pull_request" => %{"number" => 156, "url" => "https://github.com/octo/app/pull/156", "head_sha" => sha, "draft" => true},
          "pull_request_body" => body,
          "sha" => sha
        }
      ])

    assert :ok = Pipeline.finish_phase(issue, task, "build", 1, report)
    assert {:ok, %{"phase" => "qa", "status" => "qa"}} = Store.get_task(issue.id)
  end

  test "system-generated QA blockers require a diagnostic agent handoff" do
    issue = issue("octo/app#40", 40)
    table = start_board([issue], %{})
    pipeline_database!(table)

    assert {:ok, task, "build"} = Pipeline.prepare(issue)
    issue = %{issue | state: "QA", native_ref: Map.put(issue.native_ref, :project_status, "QA")}
    :ets.insert(table, {{:issue, issue.id}, issue})
    task = Map.merge(task, %{"phase" => "qa", "status" => "qa", "current_sha" => String.duplicate("a", 40)})
    assert :ok = Store.save_task(task)
    assert {:ok, task, attempt} = Pipeline.begin_phase(issue, task, "qa")

    result = %{
      "outcome" => "blocked",
      "summary" => "The workspace is not at the accepted Build SHA.",
      "reason" => "The workspace is not at the accepted Build SHA.",
      "next_step" => "Restore the accepted workspace and move the issue to Ready."
    }

    assert {:error, :diagnostic_handoff_required} =
             Pipeline.finish_phase(issue, task, "qa", attempt, {:system_blocker, result})

    assert project_state(table, issue.id) == "QA"
    assert lookup(table, {:reports, issue.id}) == nil
  end

  test "workspace preflight failures reach diagnostic instead of skill readiness" do
    issue = issue("octo/app#44", 44)
    table = start_board([issue], %{})
    pipeline_database!(table, retry_backoff_ms: 300_000)
    orchestrator = start_orchestrator(__MODULE__.WorkspacePreflightAgent)

    assert await(fn -> lookup(table, {:diagnostic_runner_calls, issue.id}) != nil end)
    assert {:ok, task} = Store.get_task(issue.id)
    refute get_in(task, ["skill_readiness", "status"]) == "failed"
    stop_orchestrator(orchestrator)
  end

  test "orchestrator retries a preflight blocker through the diagnostic lane" do
    issue = issue("octo/app#45", 45)
    issue = %{issue | state: "QA", native_ref: Map.put(issue.native_ref, :project_status, "QA")}
    table = start_board([issue], %{})
    pipeline_database!(table, retry_backoff_ms: 300_000)

    assert :ok =
             Store.save_task(%{
               "issue_id" => issue.id,
               "repository" => "octo/app",
               "branch" => issue.branch_name,
               "base_branch" => "main",
               "required_checks" => ["true"],
               "generation" => 1,
               "phase" => "qa",
               "status" => "qa",
               "attempts" => %{},
               "prior_findings" => [],
               "current_sha" => String.duplicate("a", 40),
               "pr_number" => 145
             })

    orchestrator = start_orchestrator(SymphonyElixir.PipelineIntegrationTest.DiagnosticAgent)
    Process.sleep(100)

    assert await(fn -> lookup(table, {:diagnostic_runner_calls, issue.id}) != nil end)
    assert await(fn -> lookup(table, :diagnostic_opts) != nil end)

    assert await(fn ->
             project_state(table, issue.id) == "Blocked" and
               match?({:ok, %{"status" => "blocked"}}, Store.get_task(issue.id))
           end)

    assert {:diagnostic_opts, opts} = :ets.lookup(table, :diagnostic_opts) |> List.last()
    assert Keyword.get(opts, :diagnostic) == true
    refute Keyword.has_key?(opts, :blocker_report)
    assert Map.has_key?(lookup(table, {:reports, issue.id}), "octo/app#45:1:diagnostic")

    stop_orchestrator(orchestrator)
  end

  test "open blockers wait while invalid Project dependencies go straight to diagnostics" do
    reason = "GitHub could not read complete blocker data. Correct the relationship, then move the Project item to Ready."
    issue = %{issue("octo/app#46", 46) | dependency_error: reason}
    open_blocker = %{issue | dependency_error: nil, blocked_by: [%{id: "octo/app#47", state: "OPEN"}]}
    table = start_board([issue], %{})
    pipeline_database!(table, retry_backoff_ms: 300_000)

    state = %Orchestrator.State{max_concurrent_agents: 3, running: %{}, claimed: MapSet.new(), blocked: %{}}
    refute Orchestrator.should_dispatch_issue_for_test(open_blocker, state)

    assert Orchestrator.should_dispatch_issue_for_test(
             %{open_blocker | blocked_by: [%{id: "octo/app#47", state: "CLOSED"}]},
             state
           )

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)

    orchestrator = start_orchestrator(SymphonyElixir.PipelineIntegrationTest.DiagnosticAgent)

    assert await(fn -> project_state(table, issue.id) == "Blocked" end)
    assert lookup(table, {:diagnostic_runner_calls, issue.id}) == 1
    assert agent_calls(table, issue.id) == 0
    assert {:diagnostic_opts, opts} = :ets.lookup(table, :diagnostic_opts) |> List.last()
    assert Keyword.get(opts, :diagnostic) == true
    assert Keyword.get(opts, :diagnostic_reason) == reason

    report = Jason.decode!(lookup(table, {:report, issue.id, "diagnostic"}))
    assert report["reason"] == reason
    assert report["next_step"] =~ "Ready"

    stop_orchestrator(orchestrator)
  end

  test "unconfirmed Blocked transition waits for an observed requeue before Build" do
    reason = "GitHub denied access to a blocker. Grant read access, correct the relationship, then move the item to Ready."
    issue = %{issue("octo/app#47", 47) | dependency_error: reason}
    table = start_board([issue], %{})
    pipeline_database!(table, retry_backoff_ms: 300_000)
    :ets.insert(table, {:unconfirm_status_once, true})

    orchestrator = start_orchestrator(SymphonyElixir.PipelineIntegrationTest.DiagnosticAgent)

    assert await(fn -> lookup(table, {:status_unconfirmed, issue.id}) end)
    assert project_state(table, issue.id) == "Ready"
    assert lookup(table, {:diagnostic_runner_calls, issue.id}) == 1
    assert agent_calls(table, issue.id) == 0

    assert await(fn ->
             match?(
               {:ok, %{"status" => "blocked", "diagnostic_handoff_unconfirmed" => true}},
               Store.get_task(issue.id)
             )
           end)

    assert {:ok, %{result: %{"outcome" => "blocked", "reason" => local_reason, "next_step" => next_step}}} =
             Store.latest_phase_result(issue.id, 1)

    assert local_reason =~ "No se pudo confirmar"
    assert next_step =~ "Ready"

    report = Jason.decode!(lookup(table, {:report, issue.id, "diagnostic"}))
    assert report["reason"] == reason
    assert report["next_step"] =~ "Ready"

    stop_orchestrator(orchestrator)

    corrected = %{fetch_issue(table, issue.id) | dependency_error: nil}
    :ets.insert(table, {{:issue, issue.id}, corrected})
    name = Module.concat(__MODULE__, "DiagnosticRequeue#{System.unique_integer([:positive])}")
    {:ok, orchestrator} = Orchestrator.start_link(name: name, agent_runner: HoldingAgent)
    refresh!(name, table)

    assert project_state(table, issue.id) == "Ready"
    assert agent_calls(table, issue.id, :build) == 0

    set_project_state(table, issue.id, "Blocked")
    refresh!(name, table)
    assert {:ok, %{"status" => "blocked"} = task} = Store.get_task(issue.id)
    refute Map.has_key?(task, "diagnostic_handoff_unconfirmed")

    set_project_state(table, issue.id, "Ready")
    refresh!(name, table)
    assert await(fn -> lookup(table, {:held_agent_pid, issue.id}) != nil end)
    assert agent_calls(table, issue.id, :build) == 1
    send(lookup(table, {:held_agent_pid, issue.id}), :release)
    stop_orchestrator(orchestrator)
  end

  test "invalid Project dependencies during Finalize use the diagnostic lane" do
    reason = "GitHub could not read complete blocker data. Correct the relationship, then move the Project item to Ready."

    issue = %{
      issue("octo/app#48", 48)
      | state: "Human Review",
        dependency_error: reason,
        native_ref: %{repository: "octo/app", base_branch: "main", project_status: "Human Review"}
    }

    table = start_board([issue], %{})
    pipeline_database!(table)

    task = %{
      "issue_id" => issue.id,
      "repository" => "octo/app",
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "required_checks" => ["true"],
      "generation" => 1,
      "phase" => "finalize",
      "status" => "finalize",
      "attempts" => %{},
      "prior_findings" => [],
      "current_sha" => String.duplicate("a", 40)
    }

    assert :ok = Store.save_task(task)
    sha = task["current_sha"]
    :ets.insert(table, {{:remote_sha, issue.id}, sha})

    :ets.insert(table, {
      {:pull_request, issue.id},
      %{number: 148, branch: issue.branch_name, base: "main", sha: sha, draft: false, merged: true, body: "delivery", url: "https://github.com/octo/app/pull/148"}
    })

    orchestrator = start_orchestrator(SymphonyElixir.PipelineIntegrationTest.FinalizationDiagnosticAgent)

    assert await(fn ->
             project_state(table, issue.id) == "Blocked" and
               match?({:ok, %{"status" => "blocked", "phase" => "finalize"}}, Store.get_task(issue.id))
           end)

    assert lookup(table, {:diagnostic_runner_calls, issue.id}) == 1
    assert agent_calls(table, issue.id) == 0

    report = Jason.decode!(lookup(table, {:report, issue.id, "diagnostic"}))
    assert report["reason"] == reason
    assert report["next_step"] =~ "Ready"

    :ets.insert(table, {
      {:issue, issue.id},
      %{
        issue
        | state: "Ready",
          dependency_error: nil,
          blocked_by: [%{id: "octo/app#51", state: "CLOSED"}],
          requeueable: true,
          native_ref: Map.put(issue.native_ref, :project_status, "Ready")
      }
    })

    assert await(fn ->
             project_state(table, issue.id) == "Done" and
               match?({:ok, %{"status" => "done", "phase" => "finalize"}}, Store.get_task(issue.id))
           end)

    assert lookup(table, {:agent_calls, issue.id, :finalize}) == 1

    stop_orchestrator(orchestrator)
  end

  test "open Project blockers pause pending Finalize work" do
    issue = %{
      issue("octo/app#49", 49)
      | state: "Human Review",
        blocked_by: [%{id: "octo/app#50", state: "OPEN"}],
        native_ref: %{repository: "octo/app", base_branch: "main", project_status: "Human Review"}
    }

    table = start_board([issue], %{})
    pipeline_database!(table)

    assert :ok =
             Store.save_task(%{
               "issue_id" => issue.id,
               "generation" => 1,
               "phase" => "finalize",
               "status" => "finalize"
             })

    state = %Orchestrator.State{max_concurrent_agents: 3, running: %{}, claimed: MapSet.new(), blocked: %{}}
    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    refute Orchestrator.retry_candidate_issue_for_test(issue)
    assert Orchestrator.retry_candidate_issue_for_test(%{issue | dependency_error: "Blocker data could not be read."})
  end

  test "Finalize diagnostics accept a Blocked report with a recovery step" do
    schema = SymphonyElixir.AgentRunner.phase_report_schema_for_test(:finalize, true)
    properties = schema["properties"]

    assert properties["outcome"]["enum"] == ["blocked"]
    assert "reason" in schema["required"]
    assert "next_step" in schema["required"]
    refute "reason" in SymphonyElixir.AgentRunner.phase_report_schema_for_test(:finalize, false)["required"]
  end

  test "direct QA blocks a ready PR before running workspace checks" do
    issue = issue("octo/app#143", 143)
    table = start_board([issue], %{})
    pipeline_database!(table)
    sha = String.duplicate("a", 40)
    :ets.insert(table, {{:pull_request, issue.id}, %{sha: sha, draft: false}})

    assert {:phase_result, {:system_blocker, report}} =
             AgentRunner.verify_pipeline_workspace_sha_for_test(
               "unused",
               issue,
               [phase: :qa, pipeline_task: %{"current_sha" => sha, "direct_qa" => true}],
               nil
             )

    assert report["next_step"] =~ "draft"
  end

  test "Review blocks when the PR head advances after the Build SHA was accepted" do
    issue = issue("octo/app#43", 43)
    table = start_board([issue], %{})
    pipeline_database!(table)
    accepted_sha = String.duplicate("a", 40)
    observed_sha = String.duplicate("b", 40)
    :ets.insert(table, {{:pull_request, issue.id}, %{sha: observed_sha}})

    assert {:phase_result, {:system_blocker, report}} =
             AgentRunner.verify_pipeline_workspace_sha_for_test(
               "unused",
               issue,
               [phase: :review, pipeline_task: %{"current_sha" => accepted_sha}],
               nil
             )

    assert report["outcome"] == "blocked"
    assert report["summary"] =~ accepted_sha
    assert report["summary"] =~ observed_sha
    assert report["next_step"] =~ "Build"
  end

  test "resuming a blocked Review without a PR restarts Build" do
    issue = issue("octo/app#44", 44)
    table = start_board([issue], %{})
    pipeline_database!(table)

    task = %{
      "issue_id" => issue.id,
      "repository" => "octo/app",
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "required_checks" => ["true"],
      "generation" => 1,
      "phase" => "review",
      "status" => "blocked",
      "attempts" => %{"review" => 1},
      "prior_findings" => [],
      "current_sha" => String.duplicate("a", 40),
      "pr_number" => 144
    }

    assert :ok = Store.save_task(task)

    assert {:ok, %{"phase" => "build", "status" => "building", "current_sha" => nil}, "build"} =
             Pipeline.prepare(issue)
  end

  test "resuming blocked QA restarts Build when the tracker cannot read a PR" do
    issue = issue("octo/app#45", 45)
    table = start_board([issue], %{})
    pipeline_database!(table)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    task = %{
      "issue_id" => issue.id,
      "repository" => "octo/app",
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "required_checks" => ["true"],
      "generation" => 1,
      "phase" => "qa",
      "status" => "blocked",
      "attempts" => %{"qa" => 1},
      "prior_findings" => [],
      "current_sha" => String.duplicate("a", 40),
      "pr_number" => 145
    }

    assert :ok = Store.save_task(task)
    assert :ignore = Tracker.pull_request(issue)

    assert {:ok, %{"phase" => "build", "status" => "building", "current_sha" => nil}, "build"} =
             Pipeline.prepare(issue)
  end

  test "QA finding normalization uses Spanish report values for a Spanish issue" do
    spanish_issue = %{issue("octo/app#40", 40) | description: "Implementar soporte para nuevas salas"}
    finding = %{"id" => "QA-40", "reproduction" => "Ejecuta la ruta afectada.", "criterion" => "Se cumple el criterio."}

    assert {:ok,
            %{
              "outcome" => "changes_requested",
              "summary" => "QA encontró hallazgos que requieren corrección.",
              "next_step" => "Corrige los hallazgos y vuelve a entregar el trabajo en Build."
            }} =
             Pipeline.normalize_phase_result(
               %{
                 "outcome" => "passed",
                 "summary" => "QA pasó.",
                 "sha" => String.duplicate("a", 40),
                 "criteria" => [],
                 "changes" => [],
                 "checks" => [],
                 "findings" => [finding],
                 "next_step" => "Continúa con Review."
               },
               "qa",
               Pipeline.report_locale(spanish_issue)
             )
  end

  test "Build, QA and Review resume on the same PR and Done waits for a confirmed merge" do
    issue = issue("octo/app#1", 1)

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("sha-one", issue.id), build("sha-two", issue.id)],
          qa: [qa("sha-one"), qa("sha-two")],
          review: [review("sha-one"), review("sha-two")]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert Config.settings!().merge_policy == "human"
    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    first_sha = lookup(table, {:remote_sha, issue.id})
    assert %{number: pr_number, branch: branch, sha: ^first_sha, draft: false} = pull_request(table, issue.id)
    refute pull_request(table, issue.id).merged
    assert branch == issue.branch_name
    assert pull_request(table, issue.id).body =~ "https://github.com/octo/app/issues/1"
    assert pull_request(table, issue.id).body =~ "Acceptance criterion completed."
    assert pull_request(table, issue.id).body =~ first_sha
    assert report_phases(table, issue.id) == [:build, :qa, :review]

    set_project_state(table, issue.id, "Done")
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, issue.id) == "Done" end)

    stop_orchestrator(orchestrator)
    set_project_state(table, issue.id, "Ready")
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" and agent_calls(table, issue.id) == 6 end)
    second_sha = lookup(table, {:remote_sha, issue.id})
    assert second_sha != first_sha
    assert %{number: ^pr_number, branch: ^branch, sha: ^second_sha, draft: false} = pull_request(table, issue.id)
    assert pull_request(table, issue.id).body =~ second_sha
    assert report_phases(table, issue.id) == [:build, :qa, :review, :build, :qa, :review]

    set_pull_request_merged(table, issue.id, true)
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, issue.id) == "Done" end)

    set_project_state(table, issue.id, "Ready")
    set_github_issue_state(table, issue.id, "closed")
    send(orchestrator, :tick)
    Process.sleep(50)
    assert agent_calls(table, issue.id) == 6

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "legacy issue status mappings do not remap the canonical pipeline" do
    statuses = default_status_values()

    legacy_statuses = %{
      backlog: "Ideas",
      ready: "Queued",
      building: "Implementing",
      qa: "Verifying",
      review: "Auditing",
      human_review: "Awaiting Human",
      blocked: "Needs Help",
      dropped: "Discarded",
      done: "Integrated"
    }

    issue = issue("octo/app#9", 9)

    issue = %{
      issue
      | state: statuses.ready,
        native_ref: Map.merge(issue.native_ref, %{project_status: statuses.ready, status_values: Map.new(legacy_statuses, fn {key, value} -> {Atom.to_string(key), value} end)})
    }

    table = start_board([issue], %{issue.id => %{build: [build("sha-nine", issue.id)], qa: [qa("sha-nine")], review: [review("sha-nine")]}})
    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == statuses.human_review end)

    set_project_state(table, issue.id, statuses.done)
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, issue.id) == statuses.done end)

    set_pull_request_merged(table, issue.id, true)
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, issue.id) == statuses.done end)

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "Blocked Review reruns Build and QA when the pull request head changes" do
    issue = issue("octo/app#14", 14)

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("sha-fourteen-old", issue.id), build("sha-fourteen-new", issue.id)],
          qa: [qa("sha-fourteen-old"), qa("sha-fourteen-new")],
          review: [blocked(), review("sha-fourteen-new")]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Blocked" end)
    accepted_sha = lookup(table, {:remote_sha, issue.id})
    pr = pull_request(table, issue.id)
    assert pr.sha == accepted_sha

    :ets.insert(table, {{:pull_request, issue.id}, %{pr | sha: "external-head-update"}})
    set_project_state(table, issue.id, "Ready")

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert agent_calls(table, issue.id) == 6
    assert report_phases(table, issue.id) == [:build, :qa, :review, :build, :qa, :review]
    assert pull_request(table, issue.id).sha == lookup(table, {:remote_sha, issue.id})

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "Blocked QA reruns Build when the pull request head changes" do
    issue = issue("octo/app#43", 43)

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("sha-forty-three-old", issue.id), build("sha-forty-three-new", issue.id)],
          qa: [blocked(), qa("sha-forty-three-new")],
          review: [review("sha-forty-three-new")]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Blocked" end)
    accepted_sha = lookup(table, {:remote_sha, issue.id})
    pr = pull_request(table, issue.id)
    assert pr.sha == accepted_sha

    :ets.insert(table, {{:pull_request, issue.id}, %{pr | sha: "external-head-update"}})
    set_project_state(table, issue.id, "Ready")

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert agent_calls(table, issue.id) == 5
    assert report_phases(table, issue.id) == [:build, :qa, :build, :qa, :review]
    assert pull_request(table, issue.id).sha == lookup(table, {:remote_sha, issue.id})

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "Blocked QA without an accepted SHA restarts Build before retrying" do
    issue = issue("octo/app#44", 44)
    table = start_board([issue], %{})
    path = pipeline_database!(table)

    assert {:ok, task, "build"} = Pipeline.prepare(issue)

    task =
      task
      |> Map.put("phase", "qa")
      |> Map.put("status", "blocked")
      |> Map.put("current_sha", nil)

    assert :ok = Store.save_task(task)
    assert {:ok, %{"phase" => "build", "status" => "building", "current_sha" => nil}, "build"} = Pipeline.prepare(issue)

    File.rm_rf!(Path.dirname(path))
  end

  test "no_changes waits for human confirmation, Blocked resumes, and transient failures retry" do
    no_changes = issue("octo/app#2", 2)
    blocked = issue("octo/app#3", 3)
    transient = issue("octo/app#4", 4)
    missing_check = issue("octo/app#6", 6)
    unavailable_check = issue("octo/app#10", 10)

    table =
      start_board([no_changes, blocked, transient, missing_check, unavailable_check], %{
        no_changes.id => %{build: [no_changes()]},
        blocked.id => %{build: [blocked(), build("sha-three", blocked.id)], qa: [qa("sha-three")], review: [review("sha-three")]},
        transient.id => %{build: [{:error, :temporary_failure}, build("sha-four", transient.id)], qa: [qa("sha-four")], review: [review("sha-four")]},
        missing_check.id => %{
          build: [build("sha-six-old", missing_check.id), build("sha-six-fixed", missing_check.id)],
          qa: [qa_missing_check("sha-six-old"), qa("sha-six-fixed")],
          review: [Map.put(review("sha-six-fixed"), "resolutions", ["required-check:sh ./check.sh"])]
        },
        unavailable_check.id => %{build: [build("sha-ten", unavailable_check.id)], qa: [qa_missing_check("sha-ten")]}
      })

    path = pipeline_database!(table, retry_backoff_ms: 1)
    workspace = ensure_test_workspace!(missing_check)
    File.write!(Path.join(workspace, "check.sh"), "if [ -f fail-once ]; then rm fail-once; exit 1; fi\nexit 0\n")
    File.write!(Path.join(workspace, "fail-once"), "fail once")
    File.write!(Path.join(workspace, ".git/info/exclude"), "fail-once\n", [:append])
    {_output, 0} = System.cmd("git", ["add", "check.sh"], cd: workspace, stderr_to_stdout: true)
    {_output, 0} = System.cmd("git", ["commit", "-m", "add check fixture"], cd: workspace, stderr_to_stdout: true)
    missing_check = %{missing_check | native_ref: Map.put(missing_check.native_ref, :required_checks, ["sh ./check.sh"])}
    :ets.insert(table, {{:issue, missing_check.id}, missing_check})
    unavailable_check = %{unavailable_check | native_ref: Map.put(unavailable_check.native_ref, :required_checks, ["command-that-does-not-exist"])}
    :ets.insert(table, {{:issue, unavailable_check.id}, unavailable_check})
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, no_changes.id) == "Blocked" end)
    assert report_phases(table, no_changes.id) == [:build]
    set_project_state(table, no_changes.id, "Dropped")

    send(orchestrator, :tick)
    assert await(fn -> project_state(table, no_changes.id) == "Dropped" end)

    set_issue_description(table, no_changes.id, no_changes.description <> "\n\nDrop reason: Human confirmed no changes are needed.")
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, no_changes.id) == "Dropped" end)
    assert report_phases(table, no_changes.id) == [:build]
    assert lookup(table, {:report, no_changes.id, "dropped"}) == nil
    assert project_state(table, no_changes.id) == "Dropped"

    assert await(fn -> project_state(table, blocked.id) == "Blocked" end)
    set_project_state(table, blocked.id, "Ready")
    assert await(fn -> project_state(table, blocked.id) == "Human Review" end)

    assert await(fn -> project_state(table, transient.id) == "Human Review" end)
    assert agent_calls(table, transient.id) == 4

    assert await(fn -> project_state(table, missing_check.id) == "Human Review" end)
    assert agent_calls(table, missing_check.id) == 5
    assert report_phases(table, missing_check.id) == [:build, :qa, :build, :qa, :review]
    qa_report = lookup(table, {:report, missing_check.id, "qa"})
    assert qa_report =~ "host exit status 0"
    refute qa_report =~ "agent claimed success"

    assert await(fn -> project_state(table, unavailable_check.id) == "Blocked" end)
    assert agent_calls(table, unavailable_check.id) == 2
    assert report_phases(table, unavailable_check.id) == [:build, :qa]
    assert lookup(table, {:report, unavailable_check.id, "qa"}) =~ "unavailable"

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "uncertain PR and report responses reconcile after orchestrator restarts without duplicates" do
    issue = issue("octo/app#5", 5)
    table = start_board([issue], %{issue.id => %{build: [build("sha-five", issue.id)], qa: [qa("sha-five")], review: [review("sha-five")]}})
    path = pipeline_database!(table, retry_backoff_ms: 300_000)
    :ets.insert(table, {:uncertain_pr_once, true})
    :ets.insert(table, {:uncertain_report_once, true})

    orchestrator = start_orchestrator()
    assert await(fn -> pull_request(table, issue.id) != nil end)
    assert await(fn -> :ets.lookup(table, :uncertain_pr_once) == [] end)
    stop_orchestrator(orchestrator)

    orchestrator = start_orchestrator()
    assert await(fn -> Map.has_key?(lookup(table, {:reports, issue.id}) || %{}, "#{issue.id}:1:build") end)
    assert await(fn -> :ets.lookup(table, :uncertain_report_once) == [] end)
    stop_orchestrator(orchestrator)

    orchestrator = start_orchestrator()
    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert report_phases(table, issue.id) == [:build, :qa, :review]
    assert pull_request_count(table, issue.id) == 1
    assert agent_calls(table, issue.id) == 5

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "closed merged work resumes Finalize after a lost report response and restart" do
    issue = issue("octo/app#13", 13)
    sha = "sha-thirteen"

    issue = %{
      issue
      | state: "closed",
        dispatchable: false,
        native_ref: Map.merge(issue.native_ref, %{project_status: "Human Review", issue_state: "closed"})
    }

    table = start_board([issue], %{})
    path = pipeline_database!(table, retry_backoff_ms: 300_000)

    task = %{
      "issue_id" => issue.id,
      "repository" => "octo/app",
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "required_checks" => ["true"],
      "generation" => 1,
      "phase" => "review",
      "status" => "human_review",
      "attempts" => %{"build" => 1, "qa" => 1, "review" => 1},
      "prior_findings" => [],
      "current_sha" => sha,
      "pr_number" => 113
    }

    assert :ok = Store.save_task(task)

    :ets.insert(table, {{:remote_sha, issue.id}, sha})

    :ets.insert(table, {
      {:pull_request, issue.id},
      %{
        number: 113,
        branch: issue.branch_name,
        base: "main",
        sha: sha,
        draft: false,
        merged: true,
        body: "delivery",
        url: "https://github.com/octo/app/pull/113"
      }
    })

    :ets.insert(table, {:uncertain_report_once, true})

    orchestrator = start_orchestrator()

    assert await(fn ->
             agent_calls(table, issue.id, :finalize) == 1 and
               lookup(table, :uncertain_report_once) == nil and
               not Store.agent_lease_active?(issue.id, 1, "finalize", 1)
           end)

    assert project_state(table, issue.id) == "Human Review"
    stop_orchestrator(orchestrator)

    orchestrator = start_orchestrator()

    assert await(fn ->
             project_state(table, issue.id) == "Done" and
               match?({:ok, %{"status" => "done"}}, Store.get_task(issue.id)) and
               not Store.agent_lease_active?(issue.id, 1, "finalize", 2)
           end)

    assert agent_calls(table, issue.id, :finalize) == 2
    stop_orchestrator(orchestrator)

    assert [["complete", run_result]] =
             sqlite_rows(
               path,
               "SELECT status, result FROM pipeline_runs WHERE issue_id = ? AND generation = 1 AND phase = 'finalize' AND attempt = 2",
               [issue.id]
             )

    assert Jason.decode!(run_result)["outcome"] == "merged"
    assert Jason.decode!(run_result)["_remote_evidence"] != []

    assert [["merged", ^sha, phase_result]] =
             sqlite_rows(
               path,
               "SELECT status, sha, result FROM pipeline_phases WHERE issue_id = ? AND generation = 1 AND phase = 'finalize' AND attempt = 2",
               [issue.id]
             )

    assert Jason.decode!(phase_result)["outcome"] == "merged"

    assert [[checkpoint]] =
             sqlite_rows(
               path,
               "SELECT evidence FROM pipeline_checkpoints WHERE issue_id = ? AND generation = 1 AND phase = 'finalize' AND sha = ?",
               [issue.id, sha]
             )

    assert Jason.decode!(checkpoint)["_remote_evidence"] != []
    File.rm_rf!(Path.dirname(path))
  end

  test "closed work preserves Finalize workspace and retry backoff after failures" do
    issue = issue("octo/app#14", 14)
    sha = "sha-fourteen"

    issue = %{
      issue
      | state: "closed",
        dispatchable: false,
        native_ref: Map.merge(issue.native_ref, %{project_status: "Human Review", issue_state: "closed"})
    }

    table =
      start_board([issue], %{
        issue.id => %{finalize: [{:error, :temporary_failure}, {:error, :temporary_failure}, :finalize]}
      })

    path = pipeline_database!(table, retry_backoff_ms: 1)

    task = %{
      "issue_id" => issue.id,
      "repository" => "octo/app",
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "required_checks" => ["true"],
      "generation" => 1,
      "phase" => "finalize",
      "status" => "finalize",
      "attempts" => %{"build" => 1, "qa" => 1, "review" => 1, "finalize" => 1},
      "prior_findings" => [],
      "current_sha" => sha,
      "pr_number" => 114
    }

    assert :ok = Store.save_task(task)

    :ets.insert(table, {{:remote_sha, issue.id}, sha})

    :ets.insert(table, {
      {:pull_request, issue.id},
      %{
        number: 114,
        branch: issue.branch_name,
        base: "main",
        sha: sha,
        draft: false,
        merged: true,
        body: "delivery",
        url: "https://github.com/octo/app/pull/114"
      }
    })

    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Done" end)
    assert agent_calls(table, issue.id, :finalize) == 3
    assert Enum.map(1..3, &lookup(table, {:retry_attempt, issue.id, :finalize, &1})) == [nil, 1, 2]
    refute lookup(table, {:workspace_existed, issue.id, :finalize, 1})
    assert lookup(table, {:workspace_existed, issue.id, :finalize, 2})
    assert lookup(table, {:workspace_existed, issue.id, :finalize, 3})

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "PR creation revalidates the pushed SHA after Build commits its outbox" do
    issue = issue("octo/app#7", 7)
    table = start_board([issue], %{issue.id => %{build: [build("sha-seven", issue.id)]}})
    path = pipeline_database!(table, retry_backoff_ms: 300_000)
    :ets.insert(table, {:change_sha_after_validation, true})

    orchestrator = start_orchestrator()
    assert await(fn -> agent_calls(table, issue.id, :build) == 1 end)
    Process.sleep(50)

    assert project_state(table, issue.id) == "Building"
    assert pull_request_count(table, issue.id) == 0

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "QA retries a report missing the changes summary" do
    issue = issue("octo/app#8", 8)
    incomplete = qa("sha-eight") |> Map.delete("changes")

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("sha-eight", issue.id)],
          qa: [incomplete, qa("sha-eight")],
          review: [review("sha-eight")]
        }
      })

    path = pipeline_database!(table, retry_backoff_ms: 1)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert agent_calls(table, issue.id) == 4
    assert report_phases(table, issue.id) == [:build, :qa, :review]

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "QA host checks reject workspace drift after the accepted Build SHA" do
    issue = issue("octo/app#11", 11)

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("dirty", issue.id), build("clean", issue.id)],
          qa: [qa("dirty"), qa("clean")],
          review: [Map.put(review("clean"), "resolutions", ["workspace-dirty"])]
        }
      })

    path = pipeline_database!(table)
    :ets.insert(table, {{:dirty_once, issue.id}, true})
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert agent_calls(table, issue.id) == 5
    assert report_phases(table, issue.id) == [:build, :qa, :build, :qa, :review]
    assert lookup(table, {:agent_prior_findings, issue.id, :build, 2}) |> Enum.any?(&(&1["id"] == "workspace-dirty"))

    assert table
           |> lookup({:reports, issue.id})
           |> Map.values()
           |> Enum.any?(&String.contains?(&1, "workspace"))

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "a QA report with findings returns to Build and keeps finding context through Review" do
    issue = issue("octo/app#12", 12)
    finding = %{"id" => "QA-12-1", "reproduction" => "Run the failing scenario.", "criterion" => "The result matches the acceptance criterion."}
    qa_with_finding = Map.put(qa("first"), "findings", [finding])

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("first", issue.id), build("fixed", issue.id), build("fixed-two", issue.id)],
          qa: [qa_with_finding, qa("fixed"), qa("fixed-two")],
          review: [
            review("fixed"),
            Map.put(review("fixed-two"), "resolutions", [finding["id"] <> " — resolved: confirmed in review."])
          ]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)

    assert agent_calls(table, issue.id) == 8
    assert report_phases(table, issue.id) == [:build, :qa, :build, :qa, :review, :build, :qa, :review]
    assert lookup(table, {:agent_prior_findings, issue.id, :build, 2}) == [finding]
    assert lookup(table, {:agent_prior_findings, issue.id, :build, 3}) == [finding]
    assert lookup(table, {:agent_prior_findings, issue.id, :review, 1}) == [finding]
    assert lookup(table, {:agent_prior_findings, issue.id, :review, 2}) == [finding]

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "a Review report with findings returns to Build instead of Human Review" do
    issue = issue("octo/app#13", 13)
    finding = %{"id" => "REV-13-1", "reproduction" => "Run the affected path.", "criterion" => "The implementation preserves the required behavior."}
    review_with_finding = Map.put(review("first"), "findings", [finding])

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("first", issue.id), build("fixed", issue.id)],
          qa: [qa("first"), qa("fixed")],
          review: [review_with_finding, Map.put(review("fixed"), "resolutions", [finding["id"]])]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert report_phases(table, issue.id) == [:build, :qa, :review, :build, :qa, :review]
    assert lookup(table, {:agent_prior_findings, issue.id, :build, 2}) == [finding]
    assert lookup(table, {:agent_prior_findings, issue.id, :review, 2}) == [finding]

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  defp start_board(issues, agent_results) do
    table = :ets.new(:pipeline_board, [:set, :public])
    Enum.each(issues, &:ets.insert(table, {{:issue, &1.id}, &1}))

    for {issue_id, results_by_phase} <- agent_results,
        {phase, results} <- results_by_phase,
        {result, index} <- Enum.with_index(results, 1) do
      :ets.insert(table, {{:agent_result, issue_id, phase, index}, result})
      if index == length(results), do: :ets.insert(table, {{:agent_result_fallback, issue_id, phase}, result})
    end

    table
  end

  defp pipeline_database!(table, opts \\ []) do
    env_keys = [:pipeline_test_board, :pipeline_database_path, :pipeline_test_workspace, :github_projects_client_module]
    previous_env = Map.new(env_keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})
    root = Path.join(System.tmp_dir!(), "symphony-pipeline-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "pipeline.sqlite3")
    workspace = Path.join(root, "workspaces")
    File.mkdir_p!(workspace)
    Application.put_env(:symphony_elixir, :pipeline_test_board, table)
    Application.put_env(:symphony_elixir, :github_projects_client_module, __MODULE__.FakeClient)
    Application.put_env(:symphony_elixir, :pipeline_database_path, path)
    Application.put_env(:symphony_elixir, :pipeline_test_workspace, workspace)
    write_pipeline_workflow!(Keyword.get(opts, :retry_backoff_ms, 1), Keyword.get(opts, :poll_interval_ms, 20))

    on_exit(fn ->
      File.rm_rf(root)
      if :ets.info(table) != :undefined, do: :ets.delete(table)

      Enum.each(previous_env, fn
        {key, {:ok, value}} -> Application.put_env(:symphony_elixir, key, value)
        {key, :error} -> Application.delete_env(:symphony_elixir, key)
      end)
    end)

    path
  end

  defp write_pipeline_workflow!(retry_backoff_ms, poll_interval_ms) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github_projects
      active_states: [Ready, Building, QA, Review, Human Review]
      terminal_states: [closed, Dropped]
      provider:
        owner: acme
        project_number: 1
        repositories:
          - repository: octo/app
            base_branch: main
            prepare_command: "true"
            required_checks: ["true"]
        token: test-token
    polling:
      interval_ms: #{poll_interval_ms}
    workspace:
      root: /tmp/symphony-pipeline-workspaces
    agent:
      max_concurrent_agents: 5
      max_turns: 2
      max_retry_backoff_ms: #{retry_backoff_ms}
    codex:
      stall_timeout_ms: 0
    ---
    Return JSON phase reports.
    """)

    assert :ok = WorkflowStore.force_reload()
  end

  defp default_status_values do
    %{backlog: "Backlog", ready: "Ready", building: "Building", qa: "QA", review: "Review", human_review: "Human Review", blocked: "Blocked", dropped: "Dropped", done: "Done"}
  end

  defp start_orchestrator(agent_runner \\ __MODULE__.FakeAgent) do
    name = Module.concat(__MODULE__, "Pipeline#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name, agent_runner: agent_runner)
    pid
  end

  defp stop_orchestrator(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  end

  defp refresh!(orchestrator, table) do
    previous_calls = lookup(table, :fetch_issues_by_ids_calls) || 0
    assert %{queued: true} = Orchestrator.request_refresh(orchestrator)
    assert await(fn -> (lookup(table, :fetch_issues_by_ids_calls) || 0) >= previous_calls + 2 end)
    :sys.get_state(orchestrator)
  end

  defp assert_running_agent(orchestrator, issue, agent_pid, workspace, missing_refreshes) do
    state = :sys.get_state(orchestrator)
    assert state.running[issue.id].pid == agent_pid
    assert Process.alive?(agent_pid)
    assert MapSet.member?(state.claimed, issue.id)
    assert map_size(state.running) == 1
    assert Map.get(state.running[issue.id], :consecutive_missing_refreshes, 0) == missing_refreshes
    assert state.running[issue.id].workspace_path == workspace
    assert File.dir?(workspace)
  end

  defp issue(id, number) do
    %Issue{
      id: id,
      identifier: id,
      title: "Pipeline integration #{number}",
      description: "Implement the acceptance criteria.",
      state: "Ready",
      branch_name: "symphony/octo-app-#{number}",
      url: "https://github.com/octo/app/issues/#{number}",
      dispatchable: true,
      native_ref: %{
        repository: "octo/app",
        base_branch: "main",
        prepare_command: "true",
        required_checks: ["true"],
        project_status: "Ready"
      }
    }
  end

  defp build(sha, issue_id) do
    %{
      "outcome" => "ready",
      "summary" => "Implemented the task.",
      "pull_request_body" => """
      Fixes ##{issue_id |> String.split("#") |> List.last()}

      #### Context

      Implements the assigned issue.

      #### TL;DR

      Implements the issue.

      #### Summary

      - Updated the implementation.

      #### Alternatives

      - Kept the existing implementation pattern.

      #### Test Plan

      - [x] Required checks passed.
      """,
      "criteria" => ["Acceptance criterion completed."],
      "changes" => ["Updated implementation."],
      "checks" => [],
      "risks" => [],
      "next_step" => "Run QA.",
      "sha" => sha
    }
  end

  defp qa(sha) do
    %{
      "outcome" => "passed",
      "summary" => "All required checks passed.",
      "criteria" => ["Acceptance criterion verified."],
      "changes" => [],
      "checks" => [%{"name" => "true", "status" => "passed", "evidence" => "agent report"}],
      "findings" => [],
      "next_step" => "Run autonomous review.",
      "sha" => sha
    }
  end

  defp qa_missing_check(sha) do
    %{qa(sha) | "checks" => [%{"name" => "sh ./check.sh", "status" => "passed", "evidence" => "agent claimed success"}]}
  end

  defp review(sha) do
    %{
      "outcome" => "passed",
      "summary" => "No defects found.",
      "findings" => [],
      "resolutions" => [],
      "next_step" => "Wait for human review.",
      "sha" => sha
    }
  end

  defp no_changes do
    %{
      "outcome" => "no_changes",
      "summary" => "The requested behavior already exists.",
      "reason" => "No code changes are needed.",
      "criteria" => ["All criteria already satisfied."],
      "changes" => [],
      "checks" => [],
      "risks" => [],
      "next_step" => "Wait for human confirmation.",
      "sha" => nil
    }
  end

  defp blocked do
    %{
      "outcome" => "blocked",
      "summary" => "An operator must provide access to the test environment.",
      "reason" => "Required test credentials are unavailable.",
      "criteria" => [],
      "changes" => [],
      "checks" => [],
      "risks" => ["Cannot run the required environment."],
      "next_step" => "Resolve the missing access and move the item to Ready.",
      "sha" => nil
    }
  end

  defp project_state(table, issue_id) do
    issue = fetch_issue(table, issue_id)
    Map.get(issue.native_ref || %{}, :project_status, issue.state)
  end

  defp pull_request(table, issue_id) do
    case :ets.lookup(table, {:pull_request, issue_id}) do
      [{_, pr}] -> pr
      [] -> nil
    end
  end

  defp pull_request_count(table, issue_id), do: if(pull_request(table, issue_id), do: 1, else: 0)
  defp report_phases(table, issue_id), do: lookup(table, {:report_history, issue_id}) || []
  defp agent_calls(table, issue_id), do: Enum.sum(Enum.map([:build, :qa, :review], &agent_calls(table, issue_id, &1)))
  defp agent_calls(table, issue_id, phase), do: lookup(table, {:agent_calls, issue_id, phase}) || 0

  defp set_project_state(table, issue_id, status) do
    active_states = Config.settings!().tracker.active_states
    ready_status = "Ready"
    blocked_status = "Blocked"
    issue = fetch_issue(table, issue_id)
    dispatchable = status in active_states

    updated = %{
      issue
      | state: status,
        dispatchable: dispatchable,
        requeueable: status == ready_status,
        tracker_blocked: status == blocked_status,
        native_ref: Map.put(issue.native_ref, :project_status, status)
    }

    :ets.insert(table, {{:issue, issue_id}, updated})
  end

  defp set_github_issue_state(table, issue_id, status) do
    issue = fetch_issue(table, issue_id)
    :ets.insert(table, {{:issue, issue_id}, %{issue | state: status, dispatchable: false}})
  end

  defp set_issue_description(table, issue_id, description) do
    issue = fetch_issue(table, issue_id)
    :ets.insert(table, {{:issue, issue_id}, %{issue | description: description}})
  end

  defp set_pull_request_merged(table, issue_id, value) do
    pr = pull_request(table, issue_id)
    :ets.insert(table, {{:pull_request, issue_id}, %{pr | merged: value}})
  end

  defp fetch_issue(table, issue_id), do: table |> :ets.lookup({:issue, issue_id}) |> hd() |> elem(1)

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  defp sqlite_rows(path, query, params) do
    {:ok, connection} = Exqlite.Basic.open(path)

    try do
      {:ok, _statement, _result, _connection} = result = Exqlite.Basic.exec(connection, query, params)
      {:ok, rows, _columns} = Exqlite.Basic.rows(result)
      rows
    after
      Exqlite.Basic.close(connection)
    end
  end

  def ensure_test_workspace!(issue) do
    workspace = workspace_path(issue)
    File.mkdir_p!(workspace)

    if not File.dir?(Path.join(workspace, ".git")) do
      {_output, 0} = System.cmd("git", ["init", "-b", "main"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.name", "Pipeline Test"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["config", "user.email", "pipeline-test@example.invalid"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "--allow-empty", "-m", "initial"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["switch", "-c", issue.branch_name], cd: workspace, stderr_to_stdout: true)
    end

    workspace
  end

  def workspace_path(issue) do
    root = Application.fetch_env!(:symphony_elixir, :pipeline_test_workspace)
    Path.join(root, SymphonyElixir.Workspace.workspace_key(issue))
  end

  defp await(predicate, attempts \\ 400)
  defp await(_predicate, 0), do: false

  defp await(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      await(predicate, attempts - 1)
    end
  end
end

defmodule SymphonyElixir.PipelineIntegrationTest.RealSkillPreflightAgent do
  def preflight_skills(issue, task, phase, worker_host),
    do: SymphonyElixir.AgentRunner.preflight_skills(issue, task, phase, worker_host)

  def run(_issue, _recipient, _opts), do: {:error, :preflight_should_have_stopped_claim}
end

defmodule SymphonyElixir.PipelineIntegrationTest.SlowSkillPreflightAgent do
  def preflight_skills(_issue, _task, _phase, _host) do
    table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
    :ets.insert(table, {:preflight_pid, self()})

    receive do
      :continue -> {:error, :test_preflight_failure}
    after
      1_000 -> {:error, :test_preflight_failure}
    end
  end
end

defmodule SymphonyElixir.PipelineIntegrationTest.WorkspacePreflightAgent do
  def preflight_skills(_issue, _task, _phase, _host), do: {:error, {:workspace_preflight, :project_branch_dirty}}
  defdelegate run(issue, recipient, opts), to: SymphonyElixir.PipelineIntegrationTest.DiagnosticAgent
end

defmodule SymphonyElixir.PipelineIntegrationTest.PausedReviewAgent do
  alias SymphonyElixir.PipelineIntegrationTest.{FakeAgent, FakeClient}

  def run(issue, recipient, opts) do
    if Keyword.fetch!(opts, :phase) == :review do
      task = Keyword.fetch!(opts, :pipeline_task)
      context = %{issue: issue, lane: :review, task: task, generation: Keyword.fetch!(opts, :generation), attempt: Keyword.fetch!(opts, :phase_attempt)}
      report = %{"outcome" => "passed", "summary" => "Reviewed.", "sha" => task["current_sha"], "findings" => [], "resolutions" => [], "next_step" => "Merge."}
      {:ok, passed} = FakeClient.workflow_operation(context, "handoff", %{"report" => report})
      table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
      :ets.insert(table, {{:paused_review, issue.id}, self()})

      receive do
        :finish_review -> :ok
      end

      merged = %{report | "outcome" => "merged", "next_step" => "Done."}
      {:ok, handoff} = FakeClient.workflow_operation(context, "handoff", %{"report" => merged})
      Map.put(merged, "_remote_evidence", [passed, handoff])
    else
      FakeAgent.run(issue, recipient, opts)
    end
  end
end

defmodule SymphonyElixir.PipelineIntegrationTest.FakeAgent do
  alias SymphonyElixir.GitHub.AgentTool
  alias SymphonyElixir.Pipeline
  alias SymphonyElixir.PipelineIntegrationTest.FakeClient

  def run(issue, recipient, opts) do
    phase = Keyword.fetch!(opts, :phase)
    table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
    workspace_existed? = File.dir?(SymphonyElixir.PipelineIntegrationTest.workspace_path(issue))
    workspace = SymphonyElixir.PipelineIntegrationTest.ensure_test_workspace!(issue)

    if phase in [:qa, :finalize] do
      send(recipient, {:worker_runtime_info, issue.id, %{workspace_path: workspace, worker_host: Keyword.get(opts, :worker_host)}})
    end

    count = :ets.update_counter(table, {:agent_calls, issue.id, phase}, {2, 1}, {{:agent_calls, issue.id, phase}, 0})
    :ets.insert(table, {{:retry_attempt, issue.id, phase, count}, Keyword.get(opts, :attempt)})
    :ets.insert(table, {{:workspace_existed, issue.id, phase, count}, workspace_existed?})
    :ets.insert(table, {{:agent_prior_findings, issue.id, phase, count}, Keyword.get(opts, :prior_findings, [])})

    case result_for(table, issue.id, phase, count) do
      {:error, _reason} = error ->
        error

      :finalize ->
        sha = :ets.lookup_element(table, {:remote_sha, issue.id}, 2)
        finish(issue, phase, opts, %{"outcome" => "merged", "summary" => "The merged pull request is confirmed.", "sha" => sha, "next_step" => "Done."}, [], [])

      report when is_map(report) ->
        case prepare_report(table, issue, phase, report, opts, workspace) do
          {:ok, report, host_checks, prior_evidence} -> finish(issue, phase, opts, report, host_checks, prior_evidence)
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, :missing_agent_result}
    end
  end

  defp prepare_report(table, issue, :build, report, opts, workspace) do
    with {:ok, workpad} <- workflow(issue, :build, opts, [], %{"operation" => "workpad", "body" => "### Plan\n- Implement the requested change."}),
         {:ok, claim} <- workflow(issue, :build, opts, [], %{"operation" => "claim"}) do
      case report["sha"] do
        sha when is_binary(sha) ->
          remote_sha = ensure_delivery_commit(workspace, sha)
          :ets.insert(table, {{:remote_sha, issue.id}, remote_sha})
          {:ok, Map.put(report, "sha", remote_sha), [], [workpad, claim]}

        _ ->
          {:ok, report, [], [workpad, claim]}
      end
    end
  end

  defp prepare_report(table, issue, :qa, report, opts, workspace) do
    if :ets.lookup(table, {:dirty_once, issue.id}) != [] do
      :ets.delete(table, {:dirty_once, issue.id})
      File.write!(Path.join(workspace, "qa-mutation"), "QA changed the delivered workspace")
    end

    task = Keyword.get(opts, :pipeline_task, %{})
    host_checks = Enum.map(task["required_checks"] || [], &run_check(workspace, issue, opts, task, &1))

    check_findings =
      host_checks
      |> Enum.filter(&(&1["status"] == "failed"))
      |> Enum.map(fn check ->
        %{
          "id" => check["finding_id"] || "required-check:" <> check["name"],
          "reproduction" => check["evidence"],
          "criterion" => "All required checks must pass on accepted SHA #{task["current_sha"]}."
        }
      end)

    report =
      report
      |> Map.put("sha", task["current_sha"])
      |> Map.put("checks", host_checks)
      |> Map.update("findings", check_findings, &(&1 ++ check_findings))

    with {:ok, claim} <- workflow(issue, :qa, opts, host_checks, %{"operation" => "claim"}) do
      {:ok, report, host_checks, [claim]}
    end
  end

  defp prepare_report(table, issue, :review, report, _opts, _workspace),
    do: {:ok, Map.put(report, "sha", :ets.lookup_element(table, {:remote_sha, issue.id}, 2)), [], []}

  defp ensure_delivery_commit(workspace, sha) do
    delivery_path = Path.join(workspace, "delivery.txt")

    if File.read(delivery_path) != {:ok, sha} do
      File.rm_rf!(Path.join(workspace, "qa-mutation"))
      File.write!(delivery_path, sha)
      {_output, 0} = System.cmd("git", ["add", "delivery.txt"], cd: workspace, stderr_to_stdout: true)
      {_output, 0} = System.cmd("git", ["commit", "-m", "deliver #{sha}"], cd: workspace, stderr_to_stdout: true)
    end

    {remote_sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true)
    String.trim(remote_sha)
  end

  defp run_check(workspace, issue, opts, task, command) do
    case SymphonyElixir.Workspace.run_required_check(
           workspace,
           command,
           task["current_sha"],
           issue,
           Keyword.get(opts, :worker_host)
         ) do
      {:ok, evidence} ->
        %{"name" => command, "status" => "passed", "evidence" => evidence}

      {:error, {:check_failed, status}} ->
        %{"name" => command, "status" => "failed", "evidence" => "Symphony ran the configured check at SHA #{task["current_sha"]}; host exit status #{status}."}

      {:error, {:workspace_sha_mismatch, expected_sha, observed_sha}} ->
        %{"name" => command, "status" => "failed", "finding_id" => "workspace-sha-mismatch", "evidence" => "Workspace HEAD was #{observed_sha || "unavailable"}, not accepted SHA #{expected_sha}."}

      {:error, {:workspace_dirty, expected_sha, observed_sha}} ->
        %{
          "name" => command,
          "status" => "failed",
          "finding_id" => "workspace-dirty",
          "evidence" => "Workspace had local changes at SHA #{observed_sha || "unavailable"}; accepted SHA was #{expected_sha}."
        }

      {:error, :check_unavailable} ->
        %{"name" => command, "status" => "unavailable", "evidence" => "Symphony could not execute the required check."}
    end
  end

  defp finish(issue, phase, opts, report, host_checks, prior_evidence) do
    case Pipeline.normalize_phase_result(report, Atom.to_string(phase)) do
      {:error, _reason} ->
        report

      {:ok, normalized} ->
        workpad =
          if phase == :build,
            do: {:ok, nil},
            else:
              workflow(issue, phase, opts, host_checks, %{
                "operation" => "workpad",
                "body" => "### Progress\n- Verified the current phase."
              })

        workflow_report = Map.drop(normalized, ["_host_checks", "_remote_evidence"])

        with {:ok, workpad_evidence} <- workpad,
             {:ok, handoff} <-
               workflow(issue, phase, opts, host_checks, %{
                 "operation" => "handoff",
                 "outcome" => workflow_report["outcome"],
                 "report" => workflow_report
               }) do
          evidence = Enum.reject(prior_evidence ++ [workpad_evidence, handoff], &is_nil/1)
          Map.merge(workflow_report, %{"_host_checks" => host_checks, "_remote_evidence" => evidence})
        end
    end
  end

  defp workflow(issue, phase, opts, host_checks, arguments) do
    context = %{
      issue: issue,
      lane: phase,
      task: Keyword.get(opts, :pipeline_task, %{}),
      generation: Keyword.get(opts, :generation),
      attempt: Keyword.get(opts, :phase_attempt),
      tracker_kind: "github_projects",
      merge_policy: Map.get(SymphonyElixir.Config.settings!().tracker.provider, "merge_policy", "human"),
      host_checks: host_checks
    }

    case AgentTool.execute(
           "github_workflow",
           arguments,
           agent_context: context,
           workflow_client: &FakeClient.workflow_operation/3
         ) do
      %{"success" => true, "evidence" => evidence} -> {:ok, evidence}
      _ -> {:error, :github_tool_call_failed}
    end
  end

  defp result_for(table, issue_id, :finalize, count) do
    case :ets.lookup(table, {:agent_result, issue_id, :finalize, count}) do
      [{_, result}] ->
        result

      [] ->
        case :ets.lookup(table, {:agent_result_fallback, issue_id, :finalize}) do
          [{_, result}] -> result
          [] -> :finalize
        end
    end
  end

  defp result_for(table, issue_id, phase, count) do
    case :ets.lookup(table, {:agent_result, issue_id, phase, count}) do
      [{_, result}] -> result
      [] -> :ets.lookup_element(table, {:agent_result_fallback, issue_id, phase}, 2)
    end
  end
end

defmodule SymphonyElixir.PipelineIntegrationTest.FakeClient do
  alias SymphonyElixir.Config
  alias SymphonyElixir.Pipeline.Findings
  alias SymphonyElixir.Pipeline.Store

  @statuses %{
    ready: "Ready",
    building: "Building",
    qa: "QA",
    review: "Review",
    human_review: "Human Review",
    blocked: "Blocked",
    dropped: "Dropped",
    done: "Done"
  }

  def fetch_issues_by_states(states) do
    if lookup(table(), :hide_state_listing) do
      {:ok, []}
    else
      {:ok, issues() |> Enum.filter(&(&1.state in states))}
    end
  end

  def fetch_issues_by_ids(ids) do
    table = table()
    call = :ets.update_counter(table, :fetch_issues_by_ids_calls, {2, 1}, {:fetch_issues_by_ids_calls, 0})
    :ets.insert(table, {{:fetch_issues_by_ids_call, call}, ids})

    case :ets.lookup(table, :fetch_issues_by_ids_responses) do
      [{:fetch_issues_by_ids_responses, [response | remaining]}] ->
        :ets.insert(table, {:fetch_issues_by_ids_responses, remaining})
        response

      _ ->
        {:ok, Enum.filter(issues(), &(&1.id in ids))}
    end
  end

  def claim_issue(issue), do: set_pipeline_status(issue, :building)
  def complete_issue(issue), do: set_pipeline_status(issue, :done)
  def block_issue(issue, _reason), do: set_pipeline_status(issue, :blocked)

  def workflow_operation(context, "workpad", _arguments) do
    with :ok <- validate_lease(context) do
      issue = context.issue
      {:ok, %{"issue" => %{"id" => issue.id, "url" => issue.url}, "comment" => comment_evidence(issue, "workpad-#{issue.id}")}}
    end
  end

  def workflow_operation(context, "claim", _arguments) do
    target = if context.lane == :qa, do: status_value(:qa), else: status_value(:building)

    with :ok <- validate_lease(context),
         issue = context.issue,
         current = fetch_issue(table(), issue.id),
         true <- current_project_status(current) in [status_value(:ready), status_value(:building), target] do
      current = write_project_status(current, target)
      :ets.insert(table(), {{:issue, issue.id}, current})
      {:ok, project_item_evidence(issue, current, target)}
    else
      false -> {:error, :github_human_decision_changed}
      {:error, _reason} = error -> error
    end
  end

  def workflow_operation(context, "handoff", arguments) do
    issue = context.issue
    lane = to_string(context.lane)
    report = Map.get(arguments, "report", %{})
    outcome = arguments["outcome"] || report["outcome"]
    report = report |> Map.put("outcome", outcome) |> normalize_agent_report(context)
    current = fetch_issue(table(), issue.id)
    target = target_status(lane, report["outcome"])

    with :ok <- validate_lease(context),
         true <- not is_nil(target),
         true <- handoff_source_status?(lane, current, target),
         {:ok, pr} <- handoff_pull_request(issue, context, report),
         {:ok, pr} <- update_review_stage(issue, lane, report["outcome"], pr),
         :ok <- maybe_uncertain_report(issue, context, lane, report),
         next = write_project_status(current, target),
         :ok <- maybe_close_merged_issue(issue, context, report, pr, next),
         :ok <- save_report(issue, context, lane, report),
         :ok <- save_status(issue, next, report["outcome"] == "merged") do
      evidence = %{
        "outcome" => report["outcome"],
        "reason" => report["reason"],
        "next_step" => report["next_step"],
        "issue" => %{"id" => issue.id, "url" => issue.url},
        "comment" => comment_evidence(issue, report_marker(issue, context, lane)),
        "project_item" => %{"id" => "item-#{issue.id}", "status" => target},
        "pull_request" => pr && pr_evidence(pr),
        "closed_issue" => if(report["outcome"] == "merged", do: %{"id" => issue.id, "url" => issue.url, "state" => "CLOSED"}),
        "sha" => report["sha"]
      }

      {:ok, evidence}
    else
      false -> {:error, :github_human_decision_changed}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_github_handoff}
    end
  end

  def workflow_operation(_context, _operation, _arguments), do: {:error, :unsupported_github_workflow_operation}

  def set_pipeline_status(issue, status, _reason \\ nil) do
    table = table()
    current = fetch_issue(table, issue.id)
    state = Map.fetch!(@statuses, status)

    updated = %{
      current
      | state: state,
        dispatchable: state in Config.settings!().tracker.active_states,
        requeueable: state == @statuses.ready,
        tracker_blocked: state == @statuses.blocked,
        native_ref: Map.put(current.native_ref, :project_status, state)
    }

    :ets.insert(table, {{:issue, issue.id}, updated})
    :ok
  end

  def validate_pipeline_delivery(issue, branch, sha) do
    table = table()
    valid = branch == issue.branch_name and issue.native_ref.repository == "octo/app" and lookup(table, {:remote_sha, issue.id}) == sha

    if valid and lookup(table, :change_sha_after_validation) do
      :ets.delete(table, :change_sha_after_validation)
      :ets.insert(table, {{:remote_sha, issue.id}, "changed-after-validation"})
    end

    if valid, do: :ok, else: {:error, :invalid_delivery}
  end

  def upsert_pull_request(issue, attrs) do
    table = table()

    pr =
      lookup(table, {:pull_request, issue.id}) ||
        %{
          number: 100 + issue_index(issue),
          branch: attrs.branch,
          base: attrs.base,
          sha: nil,
          draft: true,
          merged: false,
          body: attrs.body,
          url: "https://github.com/octo/app/pull/#{100 + issue_index(issue)}"
        }

    updated = %{pr | sha: attrs.sha, draft: true, body: attrs.body}
    :ets.insert(table, {{:pull_request, issue.id}, updated})

    if lookup(table, :uncertain_pr_once) do
      :ets.delete(table, :uncertain_pr_once)
      {:error, :response_lost}
    else
      {:ok, updated}
    end
  end

  def set_pull_request_stage(issue, _number, stage) do
    table = table()
    pr = lookup(table, {:pull_request, issue.id})
    updated = %{pr | draft: stage == :draft}
    :ets.insert(table, {{:pull_request, issue.id}, updated})
    {:ok, updated}
  end

  def pull_request(issue) do
    table = table()

    if (lookup(table, :fail_pr_reads) || 0) > 0 do
      :ets.update_counter(table, :fail_pr_reads, {2, -1})
      {:error, :temporary_failure}
    else
      {:ok, lookup(table, {:pull_request, issue.id})}
    end
  end

  def phase_reports(issue), do: {:ok, lookup(table(), {:remote_reports, issue.id}) || []}

  def publish_phase_report(issue, marker, body, phase) do
    table = table()
    key = {:report, issue.id, phase}
    reports = lookup(table, {:reports, issue.id}) || %{}

    if Map.has_key?(reports, marker) do
      :ok
    else
      :ets.insert(table, {{:reports, issue.id}, Map.put(reports, marker, body)})
      :ets.insert(table, {key, body})
      :ets.insert(table, {{:report_history, issue.id}, (lookup(table, {:report_history, issue.id}) || []) ++ [String.to_existing_atom(phase)]})
    end

    if lookup(table, :uncertain_report_once) do
      :ets.delete(table, :uncertain_report_once)
      {:error, :response_lost}
    else
      :ok
    end
  end

  defp normalize_agent_report(report, %{lane: :qa, task: task, host_checks: checks, issue: issue}) do
    report = Map.put(report, "checks", checks)
    required = task["required_checks"] || []

    report =
      if required_checks_passed?(required, checks) do
        report
      else
        outcome = if Enum.any?(checks, &(&1["status"] == "unavailable")), do: "blocked", else: "changes_requested"
        Map.put(report, "outcome", outcome)
      end

    if "qa" in issue.labels and report["outcome"] in ["changes_requested", "failed", "defects_found"],
      do: report |> Map.put("outcome", "blocked") |> Map.put("reason", "QA requires correction."),
      else: report
  end

  defp normalize_agent_report(report, %{lane: :review, task: task}) do
    resolutions = report["resolutions"] || []
    pending = Enum.reject(task["prior_findings"] || [], &Findings.resolved?(&1["id"], resolutions))
    findings = Enum.uniq_by((report["findings"] || []) ++ pending, & &1["id"])
    report = Map.put(report, "findings", findings)

    if report["outcome"] == "passed" and findings != [], do: Map.put(report, "outcome", "changes_requested"), else: report
  end

  defp normalize_agent_report(report, _context), do: report

  defp required_checks_passed?(required, checks) do
    passed = MapSet.new(checks, &if(&1["status"] == "passed" and is_binary(&1["evidence"]), do: &1["name"]))
    Enum.all?(required, &MapSet.member?(passed, &1))
  end

  defp handoff_pull_request(issue, context, %{"outcome" => "ready", "sha" => sha} = report)
       when context.lane in [:build, :individual] do
    table = table()
    task = context.task || %{}
    branch = task["branch"] || issue.branch_name

    if lookup(table, :change_sha_after_validation) do
      :ets.delete(table, :change_sha_after_validation)
      :ets.insert(table, {{:remote_sha, issue.id}, "changed-after-validation"})
    end

    if lookup(table, {:remote_sha, issue.id}) != sha,
      do: {:error, :github_pushed_sha_not_verified},
      else:
        upsert_pull_request(issue, %{
          branch: branch,
          base: task["base_branch"] || "main",
          sha: sha,
          body: delivery_body(issue, report)
        })
  end

  defp handoff_pull_request(issue, context, _report) when context.lane in [:qa, :review] do
    case pull_request(issue) do
      {:ok, %{} = pr} -> {:ok, pr}
      {:ok, nil} -> {:error, :pull_request_not_found}
    end
  end

  defp handoff_pull_request(_issue, _context, %{"outcome" => outcome}) when outcome in ["blocked", "no_changes"],
    do: {:ok, nil}

  defp handoff_pull_request(issue, _context, _report) do
    case pull_request(issue) do
      {:ok, %{} = pr} -> {:ok, pr}
      {:ok, nil} -> {:error, :pull_request_not_found}
    end
  end

  defp maybe_close_merged_issue(_issue, context, %{"outcome" => "merged", "sha" => sha}, pr, _next) do
    base = (context.task || %{})["base_branch"] || "main"

    if (to_string(context.lane) in ["review", "finalize"] and pr) && pr.merged && pr.base == base && pr.sha == sha,
      do: :ok,
      else: {:error, :merge_not_verified_for_finalization}
  end

  defp maybe_close_merged_issue(_issue, _context, _report, _pr, _next), do: :ok

  defp maybe_uncertain_report(issue, context, lane, report) do
    marker = report_marker(issue, context, lane)
    reports = lookup(table(), {:reports, issue.id}) || %{}
    body = Jason.encode!(report, pretty: true)
    :ets.insert(table(), {{:reports, issue.id}, Map.put(reports, marker, body)})

    if lookup(table(), :uncertain_report_once) do
      :ets.delete(table(), :uncertain_report_once)
      {:error, :response_lost}
    else
      :ok
    end
  end

  defp save_report(issue, _context, lane, report) do
    body = Jason.encode!(report, pretty: true)
    :ets.insert(table(), {{:report, issue.id, lane}, body})
    history = lookup(table(), {:report_history, issue.id}) || []
    :ets.insert(table(), {{:report_history, issue.id}, history ++ [String.to_existing_atom(lane)]})
    :ok
  end

  defp save_status(issue, updated, close_issue?) do
    if lookup(table(), :unconfirm_status_once) do
      :ets.delete(table(), :unconfirm_status_once)
      :ets.insert(table(), {{:status_unconfirmed, issue.id}, true})
      {:error, :github_project_transition_not_verified}
    else
      updated =
        if close_issue?,
          do: %{updated | native_ref: Map.put(updated.native_ref || %{}, :issue_state, "closed")},
          else: updated

      :ets.insert(table(), {{:issue, issue.id}, updated})
      :ok
    end
  end

  defp update_review_stage(issue, "review", "passed", pr), do: update_stage(issue, pr, :ready)
  defp update_review_stage(issue, "review", outcome, pr) when outcome in ["changes_requested", "failed"], do: update_stage(issue, pr, :draft)
  defp update_review_stage(_issue, _lane, _outcome, pr), do: {:ok, pr}

  defp update_stage(issue, pr, stage) do
    {:ok, updated} = set_pull_request_stage(issue, pr.number, stage)
    {:ok, updated}
  end

  defp target_status("build", "ready"), do: status_value(:qa)
  defp target_status("build", outcome) when outcome in ["blocked", "no_changes"], do: status_value(:blocked)
  defp target_status("qa", "passed"), do: status_value(:review)
  defp target_status("qa", outcome) when outcome in ["changes_requested", "failed"], do: status_value(:building)
  defp target_status("qa", "blocked"), do: status_value(:blocked)
  defp target_status("review", "passed"), do: status_value(:human_review)
  defp target_status("review", "merged"), do: status_value(:done)
  defp target_status("review", outcome) when outcome in ["changes_requested", "failed"], do: status_value(:building)
  defp target_status("review", "blocked"), do: status_value(:blocked)
  defp target_status("diagnostic", "blocked"), do: status_value(:blocked)
  defp target_status("finalize", "merged"), do: status_value(:done)
  defp target_status(_, _), do: nil

  defp handoff_source_status?(lane, issue, target) do
    status = current_project_status(issue)

    sources =
      case lane do
        "build" ->
          [status_value(:building)]

        "qa" ->
          [status_value(:qa)]

        "review" ->
          [status_value(:review), status_value(:human_review)]

        "diagnostic" ->
          Enum.map([:ready, :building, :qa, :review, :human_review], &status_value/1)

        "finalize" ->
          [status_value(:human_review), status_value(:ready)]
      end

    status in [target | sources]
  end

  defp report_marker(issue, context, lane), do: "#{issue.id}:#{context.generation}:#{lane}"

  defp comment_evidence(issue, marker),
    do: %{"id" => "comment-#{marker}", "url" => "#{issue.url}#comment-#{marker}"}

  defp project_item_evidence(issue, _current, status),
    do: %{"issue" => %{"id" => issue.id, "url" => issue.url}, "project_item" => %{"id" => "item-#{issue.id}", "status" => status}}

  defp pr_evidence(pr),
    do: %{"id" => to_string(pr.number), "number" => pr.number, "url" => pr.url, "head_sha" => pr.sha, "base" => pr.base, "draft" => pr.draft, "merged" => pr.merged}

  defp delivery_body(issue, report) do
    """
    <!-- symphony:delivery:start -->
    Issue: #{issue.url}

    ## Summary
    #{report["summary"]}

    ## Acceptance criteria
    #{Enum.map_join(report["criteria"] || [], "\n", &("- " <> &1))}

    ## Changes
    #{Enum.map_join(report["changes"] || [], "\n", &("- " <> &1))}

    ## Checks
    #{Enum.map_join(report["checks"] || [], "\n", &("- " <> Jason.encode!(&1)))}

    ## Build SHA
    `#{report["sha"]}`
    <!-- symphony:delivery:end -->
    """
    |> String.trim()
  end

  defp validate_lease(%{issue: issue, generation: generation, lane: lane, attempt: attempt} = context)
       when is_integer(generation) and is_integer(attempt) do
    phase = Map.get(context, :lease_phase, to_string(lane))

    if Store.agent_lease_active?(issue.id, generation, phase, attempt),
      do: :ok,
      else: {:error, :stale_agent_lease}
  end

  defp validate_lease(_context), do: {:error, :missing_agent_lease}

  defp current_project_status(issue), do: Map.get(issue.native_ref || %{}, :project_status, issue.state)

  defp write_project_status(issue, status) do
    settings = Config.settings!().tracker

    %{
      issue
      | state: status,
        dispatchable: status in settings.active_states,
        requeueable: status == settings.provider["status_values"]["ready"],
        tracker_blocked: status == settings.provider["status_values"]["blocked"],
        native_ref: Map.merge(issue.native_ref || %{}, %{project_status: status})
    }
  end

  defp status_value(key), do: Map.fetch!(@statuses, key)

  defp issues,
    do:
      table()
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{:issue, _id}, issue} -> [issue]
        _ -> []
      end)

  defp table, do: Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
  defp fetch_issue(table, id), do: lookup(table, {:issue, id})

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  defp issue_index(%{id: id}), do: id |> String.split("#") |> List.last() |> String.to_integer()
end

defmodule SymphonyElixir.PipelineIntegrationTest.HoldingAgent do
  alias SymphonyElixir.PipelineIntegrationTest

  def run(issue, recipient, opts) do
    table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
    workspace = PipelineIntegrationTest.ensure_test_workspace!(issue)
    :ets.insert(table, {{:held_agent_pid, issue.id}, self()})
    :ets.update_counter(table, {:agent_calls, issue.id, :build}, {2, 1}, {{:agent_calls, issue.id, :build}, 0})
    send(recipient, {:worker_runtime_info, issue.id, %{workspace_path: workspace, worker_host: Keyword.get(opts, :worker_host)}})

    receive do
      :release -> :ok
    end
  end
end

defmodule SymphonyElixir.PipelineIntegrationTest.DiagnosticAgent do
  alias SymphonyElixir.GitHub.AgentTool
  alias SymphonyElixir.PipelineIntegrationTest.FakeClient

  def run(issue, _recipient, opts) do
    table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
    :ets.update_counter(table, {:diagnostic_runner_calls, issue.id}, {2, 1}, {{:diagnostic_runner_calls, issue.id}, 0})

    if Keyword.get(opts, :diagnostic, false) do
      run_diagnostic(issue, opts)
    else
      {:system_blocker,
       %{
         "outcome" => "blocked",
         "summary" => "The host could not verify the accepted workspace SHA.",
         "reason" => "The host could not verify the accepted workspace SHA.",
         "next_step" => "Inspect the saved phase evidence and current PR."
       }}
    end
  end

  defp run_diagnostic(issue, opts) do
    table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
    :ets.insert(table, {:diagnostic_opts, opts})

    reason = Keyword.get(opts, :diagnostic_reason) || "The PR head no longer matches the accepted QA SHA."
    next_step = if Keyword.has_key?(opts, :diagnostic_reason), do: "Correct the relationship, then move the issue to Ready.", else: "Move the issue to Ready to rerun Build, QA, and Review."

    report = %{
      "outcome" => "blocked",
      "summary" => reason,
      "reason" => reason,
      "next_step" => next_step,
      "sha" => String.duplicate("a", 40),
      "findings" => [],
      "criteria" => [],
      "changes" => [],
      "checks" => []
    }

    with {:ok, workpad} <- workflow(issue, opts, %{"operation" => "workpad", "body" => "### Diagnosis\nThe PR head changed."}),
         {:ok, handoff} <- workflow(issue, opts, %{"operation" => "handoff", "outcome" => "blocked", "report" => report}) do
      Map.put(report, "_remote_evidence", [workpad, handoff])
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp workflow(issue, opts, arguments) do
    context = %{
      issue: issue,
      lane: :diagnostic,
      task: Keyword.get(opts, :pipeline_task),
      generation: Keyword.get(opts, :generation),
      attempt: Keyword.get(opts, :phase_attempt),
      lease_phase: Keyword.fetch!(opts, :phase) |> to_string(),
      tracker_kind: "github_projects",
      merge_policy: "human",
      host_checks: []
    }

    case AgentTool.execute("github_workflow", arguments,
           agent_context: context,
           workflow_client: &FakeClient.workflow_operation/3
         ) do
      %{"success" => true, "evidence" => evidence} -> {:ok, evidence}
      _ -> {:error, :github_tool_call_failed}
    end
  end
end

defmodule SymphonyElixir.PipelineIntegrationTest.FinalizationDiagnosticAgent do
  alias SymphonyElixir.PipelineIntegrationTest.DiagnosticAgent
  alias SymphonyElixir.PipelineIntegrationTest.FakeAgent

  def run(issue, recipient, opts) do
    if Keyword.get(opts, :diagnostic, false),
      do: DiagnosticAgent.run(issue, recipient, opts),
      else: FakeAgent.run(issue, recipient, opts)
  end
end
