defmodule SymphonyElixir.PipelineIntegrationTest do
  use SymphonyElixir.TestSupport

  test "Build, QA and Review resume on the same PR and Done waits for a confirmed merge" do
    issue = issue("octo/app#1", 1)

    table =
      start_board([issue], %{
        issue.id => %{
          build: [build("sha-one"), build("sha-two")],
          qa: [qa("sha-one"), qa("sha-two")],
          review: [review("sha-one"), review("sha-two")]
        }
      })

    path = pipeline_database!(table)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert %{number: pr_number, branch: branch, sha: "sha-one", draft: false} = pull_request(table, issue.id)
    assert branch == issue.branch_name
    assert report_phases(table, issue.id) == [:build, :qa, :review]

    set_project_state(table, issue.id, "Done")
    send(orchestrator, :tick)
    assert await(fn -> project_state(table, issue.id) == "Human Review" end)

    stop_orchestrator(orchestrator)
    set_project_state(table, issue.id, "Ready")
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, issue.id) == "Human Review" and agent_calls(table, issue.id) == 6 end)
    assert %{number: ^pr_number, branch: ^branch, sha: "sha-two", draft: false} = pull_request(table, issue.id)
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

  test "no_changes waits for human confirmation, Blocked resumes, and transient failures retry" do
    no_changes = issue("octo/app#2", 2)
    blocked = issue("octo/app#3", 3)
    transient = issue("octo/app#4", 4)
    missing_check = issue("octo/app#6", 6)

    table =
      start_board([no_changes, blocked, transient, missing_check], %{
        no_changes.id => %{build: [no_changes()]},
        blocked.id => %{build: [blocked(), build("sha-three")], qa: [qa("sha-three")], review: [review("sha-three")]},
        transient.id => %{build: [{:error, :temporary_failure}, build("sha-four")], qa: [qa("sha-four")], review: [review("sha-four")]},
        missing_check.id => %{build: [build("sha-six-old"), build("sha-six-fixed")], qa: [qa_missing_check("sha-six-old"), qa("sha-six-fixed")], review: [review("sha-six-fixed")]}
      })

    path = pipeline_database!(table, retry_backoff_ms: 1)
    orchestrator = start_orchestrator()

    assert await(fn -> project_state(table, no_changes.id) == "Blocked" end)
    assert report_phases(table, no_changes.id) == [:build]
    set_project_state(table, no_changes.id, "Dropped")

    assert await(fn -> report_phases(table, no_changes.id) == [:build, :dropped] end)
    assert project_state(table, no_changes.id) == "Dropped"

    assert await(fn -> project_state(table, blocked.id) == "Blocked" end)
    set_project_state(table, blocked.id, "Ready")
    assert await(fn -> project_state(table, blocked.id) == "Human Review" end)

    assert await(fn -> project_state(table, transient.id) == "Human Review" end)
    assert agent_calls(table, transient.id) == 4

    assert await(fn -> project_state(table, missing_check.id) == "Human Review" end)
    assert agent_calls(table, missing_check.id) == 5
    assert report_phases(table, missing_check.id) == [:build, :qa, :build, :qa, :review]

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "uncertain PR and report responses reconcile after orchestrator restarts without duplicates" do
    issue = issue("octo/app#5", 5)
    table = start_board([issue], %{issue.id => %{build: [build("sha-five")], qa: [qa("sha-five")], review: [review("sha-five")]}})
    path = pipeline_database!(table, retry_backoff_ms: 300_000)
    :ets.insert(table, {:uncertain_pr_once, true})
    :ets.insert(table, {:uncertain_report_once, true})

    orchestrator = start_orchestrator()
    assert await(fn -> pull_request(table, issue.id) != nil end)
    assert await(fn -> :ets.lookup(table, :uncertain_pr_once) == [] end)
    stop_orchestrator(orchestrator)

    orchestrator = start_orchestrator()
    assert await(fn -> report_phases(table, issue.id) == [:build] end)
    assert await(fn -> :ets.lookup(table, :uncertain_report_once) == [] end)
    stop_orchestrator(orchestrator)

    orchestrator = start_orchestrator()
    assert await(fn -> project_state(table, issue.id) == "Human Review" end)
    assert report_phases(table, issue.id) == [:build, :qa, :review]
    assert pull_request_count(table, issue.id) == 1
    assert agent_calls(table, issue.id) == 3

    stop_orchestrator(orchestrator)
    File.rm_rf!(Path.dirname(path))
  end

  test "PR creation revalidates the pushed SHA after Build commits its outbox" do
    issue = issue("octo/app#7", 7)
    table = start_board([issue], %{issue.id => %{build: [build("sha-seven")]}})
    path = pipeline_database!(table)
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
          build: [build("sha-eight")],
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

  defp start_board(issues, agent_results) do
    table = :ets.new(:pipeline_board, [:set, :public])
    Enum.each(issues, &:ets.insert(table, {{:issue, &1.id}, &1}))

    for {issue_id, results_by_phase} <- agent_results,
        {phase, results} <- results_by_phase,
        {result, index} <- Enum.with_index(results, 1) do
      :ets.insert(table, {{:agent_result, issue_id, phase, index}, result})
    end

    table
  end

  defp pipeline_database!(table, opts \\ []) do
    env_keys = [:pipeline_test_board, :pipeline_database_path, :github_projects_client_module]
    previous_env = Map.new(env_keys, &{&1, Application.fetch_env(:symphony_elixir, &1)})
    root = Path.join(System.tmp_dir!(), "symphony-pipeline-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "pipeline.sqlite3")
    Application.put_env(:symphony_elixir, :pipeline_test_board, table)
    Application.put_env(:symphony_elixir, :github_projects_client_module, __MODULE__.FakeClient)
    Application.put_env(:symphony_elixir, :pipeline_database_path, path)
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
        status_field: Status
        status_values: {ready: Ready, building: Building, qa: QA, review: Review, human_review: Human Review, blocked: Blocked, dropped: Dropped, done: Done}
        repositories:
          - repository: octo/app
            base_branch: main
            prepare_command: "true"
            required_checks: ["mix test"]
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

  defp start_orchestrator do
    name = Module.concat(__MODULE__, "Pipeline#{System.unique_integer([:positive])}")
    {:ok, pid} = Orchestrator.start_link(name: name, agent_runner: __MODULE__.FakeAgent)
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
        required_checks: ["mix test"],
        project_status: "Ready"
      }
    }
  end

  defp build(sha) do
    %{
      "outcome" => "ready",
      "summary" => "Implemented the task.",
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
      "checks" => [%{"name" => "mix test", "status" => "passed", "evidence" => "42 tests passed"}],
      "findings" => [],
      "next_step" => "Run autonomous review.",
      "sha" => sha
    }
  end

  defp qa_missing_check(sha) do
    %{qa(sha) | "checks" => []}
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

  defp project_state(table, issue_id), do: table |> fetch_issue(issue_id) |> Map.fetch!(:state)

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
    issue = fetch_issue(table, issue_id)
    dispatchable = status in ["Ready", "Building", "QA", "Review", "Human Review"]
    updated = %{issue | state: status, dispatchable: dispatchable, requeueable: status == "Ready", native_ref: Map.put(issue.native_ref, :project_status, status)}
    :ets.insert(table, {{:issue, issue_id}, updated})
  end

  defp set_github_issue_state(table, issue_id, status) do
    issue = fetch_issue(table, issue_id)
    :ets.insert(table, {{:issue, issue_id}, %{issue | state: status, dispatchable: false}})
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
  def run(issue, _recipient, opts) do
    phase = Keyword.fetch!(opts, :phase)
    table = Application.fetch_env!(:symphony_elixir, :pipeline_test_board)
    count = :ets.update_counter(table, {:agent_calls, issue.id, phase}, {2, 1}, {{:agent_calls, issue.id, phase}, 0})
    result = table |> :ets.lookup({:agent_result, issue.id, phase, count}) |> hd() |> elem(1)

    if phase == :build and is_map(result) and is_binary(result["sha"]) do
      :ets.insert(table, {{:remote_sha, issue.id}, result["sha"]})
    end

    result
  end
end

defmodule SymphonyElixir.PipelineIntegrationTest.FakeClient do
  @statuses %{build: "Building", building: "Building", qa: "QA", review: "Review", human_review: "Human Review", blocked: "Blocked", dropped: "Dropped", done: "Done"}

  def fetch_issues_by_states(states) do
    {:ok, issues() |> Enum.filter(&(&1.state in states))}
  end

  def fetch_issues_by_ids(ids), do: {:ok, Enum.filter(issues(), &(&1.id in ids))}
  def claim_issue(issue), do: set_pipeline_status(issue, :build)
  def complete_issue(issue), do: set_pipeline_status(issue, :done)
  def block_issue(issue, _reason), do: set_pipeline_status(issue, :blocked)

  def set_pipeline_status(issue, status, _reason \\ nil) do
    table = table()
    current = fetch_issue(table, issue.id)
    state = Map.fetch!(@statuses, status)

    updated = %{
      current
      | state: state,
        dispatchable: state in ["Ready", "Building", "QA", "Review", "Human Review"],
        requeueable: state == "Ready",
        tracker_blocked: state == "Blocked",
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
        %{number: 100 + issue_index(issue), branch: attrs.branch, base: attrs.base, sha: nil, draft: true, merged: false, url: "https://github.com/octo/app/pull/#{100 + issue_index(issue)}"}

    updated = %{pr | sha: attrs.sha, draft: true}
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
