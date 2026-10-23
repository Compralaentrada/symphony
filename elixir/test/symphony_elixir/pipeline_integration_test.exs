defmodule SymphonyElixir.PipelineIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.Pipeline
  alias SymphonyElixir.Pipeline.Store

  test "pipeline reconciliation fetches all task issues in one tracker lookup" do
    issues = [issue("octo/app#20", 20), issue("octo/app#21", 21)]
    table = start_board(issues, %{})
    pipeline_database!(table)

    Enum.each(issues, fn issue ->
      assert {:ok, _task, "build"} = Pipeline.prepare(issue)
    end)

    assert :ok = Pipeline.reconcile()
    assert [{:fetch_issues_by_ids_calls, 1}] = :ets.lookup(table, :fetch_issues_by_ids_calls)
    assert [{{:fetch_issues_by_ids_call, 1}, ids}] = :ets.lookup(table, {:fetch_issues_by_ids_call, 1})
    assert MapSet.new(ids) == MapSet.new(Enum.map(issues, & &1.id))
  end

  test "pipeline reconciliation blocks a Build checkpoint that conflicts with QA until the item is Ready" do
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
    assert :ignore = Pipeline.prepare(issue)
    assert {:ok, %{"status" => "blocked", "blocked_reason" => reason}} = Store.get_task(issue.id)
    assert reason =~ "checkpoint is Build"
    assert :ok = Store.save_task(task)
    assert :ok = Pipeline.reconcile()

    assert {:ok, %{"status" => "blocked", "blocked_reason" => reason}} = Store.get_task(issue.id)
    assert reason =~ "checkpoint is Build"
    assert reason =~ "tracker state is QA"
    assert project_state(table, issue.id) == "QA"

    ready_issue = %{issue | state: "Ready", requeueable: true, native_ref: Map.put(issue.native_ref, :project_status, "Ready")}
    :ets.insert(table, {{:issue, issue.id}, ready_issue})

    assert {:ok, %{"status" => "building", "phase" => "build"} = resumed, "build"} =
             Pipeline.prepare(ready_issue)

    refute Map.has_key?(resumed, "blocked_reason")
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

  test "QA normalization rejects reports that omit issue acceptance criteria" do
    description = "## Acceptance Criteria\n- First criterion.\n- Second criterion."

    assert {:error, {:invalid_phase_report, %{phase: "qa"}}} =
             Pipeline.normalize_phase_result(qa(String.duplicate("a", 40)), "qa", :en, description)
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

    report =
      qa(String.duplicate("a", 40))
      |> Map.merge(%{"summary" => "QA pasó.", "findings" => [finding], "next_step" => "Continúa con Review."})

    assert {:ok,
            %{
              "outcome" => "changes_requested",
              "summary" => "QA encontró hallazgos que requieren corrección.",
              "next_step" => "Corrige los hallazgos y vuelve a entregar el trabajo en Build."
            }} =
             Pipeline.normalize_phase_result(
               report,
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
          qa: [qa_blocked("sha-forty-three-old"), qa("sha-forty-three-new")],
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
    latest_qa_report = lookup(table, {:report, missing_check.id, "qa"}) |> Jason.decode!()
    assert [%{"id" => "qa-unit-test"}] = latest_qa_report["checks"]
    assert Enum.any?(latest_qa_report["host_checks"], &(&1["source"] == "host" and &1["status"] == "passed" and &1["evidence"] =~ "host exit status 0"))

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
    write_pipeline_workflow!(Keyword.get(opts, :retry_backoff_ms, 1))

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

  defp write_pipeline_workflow!(retry_backoff_ms) do
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
      interval_ms: 20
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
      "criteria" => [
        %{
          "criterion" => "Acceptance criterion verified.",
          "status" => "passed",
          "procedure" => "Run the focused unit test and compare its result with the expected behavior.",
          "evidence" => ["qa-unit-test"]
        }
      ],
      "changes" => [],
      "checks" => [
        %{
          "id" => "qa-unit-test",
          "layer" => "unit",
          "command" => "mix test test/symphony_elixir/qa_report_test.exs",
          "status" => "passed",
          "result" => "1 test, 0 failures.",
          "evidence" => "test-output: qa-unit-test",
          "required" => true,
          "reason" => nil
        }
      ],
      "gaps" => [],
      "findings" => [],
      "next_step" => "Run autonomous review.",
      "reason" => nil,
      "sha" => sha
    }
  end

  defp qa_missing_check(sha) do
    report = qa(sha)

    report
    |> Map.put("checks", [
      %{
        "id" => "agent-claimed-check",
        "layer" => "unit",
        "command" => "sh ./check.sh",
        "status" => "passed",
        "result" => "The command exited successfully.",
        "evidence" => "agent claimed success",
        "required" => true,
        "reason" => nil
      }
    ])
    |> put_in(["criteria", Access.at(0), "evidence"], ["agent-claimed-check"])
  end

  defp qa_blocked(sha) do
    %{
      "outcome" => "blocked",
      "summary" => "QA cannot access the required test environment.",
      "sha" => sha,
      "criteria" => [
        %{
          "criterion" => "Acceptance criterion verified.",
          "status" => "unavailable",
          "procedure" => "Run the focused unit test in the required environment.",
          "evidence" => ["qa-environment"]
        }
      ],
      "changes" => [],
      "checks" => [
        %{
          "id" => "qa-environment",
          "layer" => "manual",
          "command" => nil,
          "status" => "unavailable",
          "result" => "The test environment could not be reached.",
          "evidence" => "test-environment access error",
          "required" => true,
          "reason" => "The test environment is inaccessible."
        }
      ],
      "host_checks" => [],
      "gaps" => [
        %{
          "scenario" => "The test environment is inaccessible.",
          "impact" => "The acceptance criterion cannot be verified.",
          "missing_coverage" => "A passing run of the focused unit test.",
          "priority" => "high"
        }
      ],
      "findings" => [],
      "reason" => "QA cannot access the required test environment.",
      "next_step" => "Restore test environment access and rerun QA on the same SHA."
    }
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
      |> Map.put("host_checks", host_checks)
      |> Map.update("findings", check_findings, &(&1 ++ check_findings))

    report =
      if Enum.any?(host_checks, &(&1["status"] == "unavailable")) do
        Map.merge(report, %{
          "outcome" => "blocked",
          "summary" => "Symphony could not execute every configured required check.",
          "reason" => "The configured check is unavailable in the task host.",
          "next_step" => "Repair the task environment and rerun QA on the same SHA."
        })
      else
        report
      end

    {:ok, report, host_checks, []}
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
        %{"name" => command, "status" => "passed", "evidence" => evidence, "source" => "host"}

      {:error, {:check_failed, status}} ->
        %{"name" => command, "status" => "failed", "evidence" => "Symphony ran the configured check at SHA #{task["current_sha"]}; host exit status #{status}.", "source" => "host"}

      {:error, {:workspace_sha_mismatch, expected_sha, observed_sha}} ->
        %{
          "name" => command,
          "status" => "failed",
          "finding_id" => "workspace-sha-mismatch",
          "evidence" => "Workspace HEAD was #{observed_sha || "unavailable"}, not accepted SHA #{expected_sha}.",
          "source" => "host"
        }

      {:error, {:workspace_dirty, expected_sha, observed_sha}} ->
        %{
          "name" => command,
          "status" => "failed",
          "finding_id" => "workspace-dirty",
          "evidence" => "Workspace had local changes at SHA #{observed_sha || "unavailable"}; accepted SHA was #{expected_sha}.",
          "source" => "host"
        }

      {:error, :check_unavailable} ->
        %{
          "name" => command,
          "status" => "unavailable",
          "evidence" => "Symphony could not execute the required check.",
          "reason" => "The configured command is unavailable in the task host.",
          "source" => "host"
        }
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
          workflow_report = Map.put(workflow_report, "outcome", handoff["outcome"] || workflow_report["outcome"])
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
    {:ok, issues() |> Enum.filter(&(&1.state in states))}
  end

  def fetch_issues_by_ids(ids) do
    table = table()
    call = :ets.update_counter(table, :fetch_issues_by_ids_calls, {2, 1}, {:fetch_issues_by_ids_calls, 0})
    :ets.insert(table, {{:fetch_issues_by_ids_call, call}, ids})
    {:ok, Enum.filter(issues(), &(&1.id in ids))}
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
    with :ok <- validate_lease(context),
         issue = context.issue,
         current = fetch_issue(table(), issue.id),
         true <- current_project_status(current) in [status_value(:ready), status_value(:building)] do
      current = write_project_status(current, status_value(:building))
      :ets.insert(table(), {{:issue, issue.id}, current})
      {:ok, project_item_evidence(issue, current, status_value(:building))}
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

  def pull_request(issue), do: {:ok, lookup(table(), {:pull_request, issue.id})}

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

  defp normalize_agent_report(report, %{lane: :qa, task: task, host_checks: checks}) do
    checks = Enum.map(checks, &Map.put(&1, "source", "host"))
    report = Map.put(report, "host_checks", checks)
    required = task["required_checks"] || []
    statuses = Enum.map(required, &required_check_status(&1, checks))

    cond do
      Enum.all?(statuses, &(&1 == :passed)) ->
        report

      Enum.any?(statuses, &(&1 == :unavailable)) ->
        Map.merge(report, %{
          "outcome" => "blocked",
          "summary" => "Symphony could not execute every configured required check.",
          "reason" => "The configured check is unavailable in the task host.",
          "next_step" => "Repair the task environment and rerun QA on the same SHA."
        })

      true ->
        Map.merge(report, %{
          "outcome" => "changes_requested",
          "summary" => "One or more required host checks failed or were missing.",
          "next_step" => "Fix the failed check and submit a new Build delivery."
        })
    end
  end

  defp normalize_agent_report(report, %{lane: :review, task: task}) do
    resolutions = report["resolutions"] || []
    pending = Enum.reject(task["prior_findings"] || [], &Findings.resolved?(&1["id"], resolutions))
    findings = Enum.uniq_by((report["findings"] || []) ++ pending, & &1["id"])
    report = Map.put(report, "findings", findings)

    if report["outcome"] == "passed" and findings != [], do: Map.put(report, "outcome", "changes_requested"), else: report
  end

  defp normalize_agent_report(report, _context), do: report

  defp required_check_status(command, checks) do
    case Enum.find(checks, &(&1["name"] == command and &1["source"] == "host")) do
      %{"status" => "passed", "evidence" => evidence} when is_binary(evidence) and evidence != "" -> :passed
      %{"status" => "failed"} -> :failed
      _ -> :unavailable
    end
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
    updated =
      if close_issue?,
        do: %{updated | native_ref: Map.put(updated.native_ref || %{}, :issue_state, "closed")},
        else: updated

    :ets.insert(table(), {{:issue, issue.id}, updated})
    :ok
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
        "build" -> [status_value(:building)]
        "qa" -> [status_value(:qa)]
        "review" -> [status_value(:review), status_value(:human_review)]
        "diagnostic" -> [status_value(:building), status_value(:qa), status_value(:review)]
        "finalize" -> [status_value(:human_review)]
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

defmodule SymphonyElixir.PipelineIntegrationTest.DiagnosticAgent do
  alias SymphonyElixir.GitHub.AgentTool
  alias SymphonyElixir.PipelineIntegrationTest.FakeClient

  def run(issue, _recipient, opts) do
    table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
    :ets.update_counter(table, {:diagnostic_runner_calls, issue.id}, {2, 1}, {{:diagnostic_runner_calls, issue.id}, 0})

    if Keyword.get(opts, :diagnostic, false) do
      run_diagnostic(issue, opts)
    else
      {:phase_result,
       {:system_blocker,
        %{
          "outcome" => "blocked",
          "summary" => "The host could not verify the accepted workspace SHA.",
          "reason" => "The host could not verify the accepted workspace SHA.",
          "next_step" => "Inspect the saved phase evidence and current PR."
        }}}
    end
  end

  defp run_diagnostic(issue, opts) do
    table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
    :ets.insert(table, {:diagnostic_opts, opts})

    report = %{
      "outcome" => "blocked",
      "summary" => "The PR head no longer matches the accepted QA SHA.",
      "reason" => "The PR head no longer matches the accepted QA SHA.",
      "next_step" => "Move the issue to Ready to rerun Build, QA, and Review.",
      "sha" => String.duplicate("a", 40),
      "findings" => [],
      "criteria" => [],
      "changes" => [],
      "checks" => [],
      "host_checks" => [],
      "gaps" => []
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
