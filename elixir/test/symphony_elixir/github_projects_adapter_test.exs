defmodule SymphonyElixir.GitHubProjectsAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{AgentReport, AgentTool, Projects.Adapter, Projects.Client}
  alias SymphonyElixir.GitHubProjectsAdapterTest.FakeGitHubProjectsClient
  alias SymphonyElixir.Pipeline.Store

  test "tracker selects the GitHub Projects adapter" do
    assert {:ok, Adapter} =
             Tracker.adapter_for_kind("github_projects")
  end

  test "the tracker exposes scoped GitHub tools and does not write through lifecycle callbacks" do
    previous_client = Application.get_env(:symphony_elixir, :github_projects_client_module)
    previous_owner = Application.get_env(:symphony_elixir, :projects_lifecycle_test_owner)

    Application.put_env(
      :symphony_elixir,
      :github_projects_client_module,
      FakeGitHubProjectsClient
    )

    Application.put_env(:symphony_elixir, :projects_lifecycle_test_owner, self())
    write_projects_workflow!()

    on_exit(fn ->
      restore_application_env(:github_projects_client_module, previous_client)
      restore_application_env(:projects_lifecycle_test_owner, previous_owner)
    end)

    issue = %Issue{id: "octo/app#7", identifier: "octo/app#7", native_ref: %{repository: "octo/app"}}
    binding = Tracker.bind_agent_tools(%{issue: issue, lane: :individual})
    assert binding.adapter == Adapter
    assert Enum.map(binding.tool_specs, & &1["name"]) == ["github_api", "github_workflow"]
    assert "GITHUB_TOKEN" in binding.secret_environment_names

    assert {:ok, []} = Tracker.fetch_issues_by_states(["Ready"])
    assert_receive {:projects_fetch_states, ["Ready"]}
    assert {:ok, []} = Tracker.fetch_issues_by_ids(["octo/app#7"])
    assert_receive {:projects_fetch_ids, ["octo/app#7"]}

    tool_result =
      Tracker.execute_bound_agent_tool(
        binding,
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn method, path, _params, _body, opts ->
          assert method == "GET"
          assert path == "/user"
          assert get_in(opts, [:tracker_settings, Access.key!(:provider), "repo"]) == "octo/app"
          {:ok, %{status: 200, body: %{"login" => "test-user"}}}
        end
      )

    assert tool_result["success"]

    fallback_tool_result =
      Adapter.execute_agent_tool(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        tracker_settings: %{provider: %{"repositories" => []}},
        agent_context: %{issue: issue, lane: :individual},
        github_client: fn _method, _path, _params, _body, opts ->
          assert get_in(opts, [:tracker_settings, :provider, "repo"]) == nil
          {:ok, %{status: 200, body: %{"login" => "test-user"}}}
        end
      )

    assert fallback_tool_result["success"]

    assert :ignore = Tracker.claim_issue(issue)
    assert :ignore = Tracker.complete_issue(issue)
    assert :ignore = Tracker.block_issue(issue, "operator input required")
    assert :ignore = Tracker.set_pipeline_status(issue, :done)
    assert :ignore = Tracker.upsert_pull_request(issue, %{})
    assert :ignore = Tracker.set_pull_request_stage(issue, 1, :draft)
    assert :ignore = Tracker.publish_phase_report(issue, "marker", "report", "build")
    refute_received {:projects_claim, _}
    refute_received {:projects_complete, _}
    refute_received {:projects_block, _, _}
    refute_received {:projects_pipeline_status, _, _, _}
  end

  test "Projects adapter forwards legacy lifecycle and pull request callbacks" do
    previous_client = Application.get_env(:symphony_elixir, :github_projects_client_module)
    previous_owner = Application.get_env(:symphony_elixir, :projects_lifecycle_test_owner)
    Application.put_env(:symphony_elixir, :github_projects_client_module, FakeGitHubProjectsClient)
    Application.put_env(:symphony_elixir, :projects_lifecycle_test_owner, self())

    on_exit(fn ->
      restore_application_env(:github_projects_client_module, previous_client)
      restore_application_env(:projects_lifecycle_test_owner, previous_owner)
    end)

    issue = %Issue{id: "octo/app#8", identifier: "octo/app#8"}

    assert :ok = Adapter.claim_issue(issue)
    assert_receive {:projects_claim, ^issue}
    assert :ok = Adapter.complete_issue(issue)
    assert_receive {:projects_complete, ^issue}
    assert :ok = Adapter.block_issue(issue, "blocked")
    assert_receive {:projects_block, ^issue, "blocked"}
    assert :ok = Adapter.set_pipeline_status(issue, :blocked, "blocked")
    assert_receive {:projects_pipeline_status, ^issue, :blocked, "blocked"}

    assert :ok = Adapter.validate_pipeline_delivery(issue, "branch", "sha")
    assert_receive {:projects_delivery, ^issue, "branch", "sha"}

    assert {:ok, %{number: 8}} = Adapter.upsert_pull_request(issue, %{number: 8})
    assert_receive {:projects_upsert_pull_request, ^issue, %{number: 8}}
    assert {:ok, %{number: 8}} = Adapter.set_pull_request_stage(issue, 8, :ready)
    assert_receive {:projects_pull_request_stage, ^issue, 8, :ready}
    assert {:ok, %{number: 8}} = Adapter.pull_request(issue)
    assert_receive {:projects_pull_request, ^issue}
    assert :ok = Adapter.publish_phase_report(issue, "marker", "body", "build")
    assert_receive {:projects_phase_report, ^issue, "marker", "body", "build"}
    assert [%{"name" => "github_api"}] = Adapter.agent_tool_specs()
  end

  test "a stale Build claim does not overwrite a human requeue to Ready" do
    alias SymphonyElixir.Pipeline.Store

    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-project-claim-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    number = System.unique_integer([:positive])
    issue_id = "octo/app##{number}"
    issue = %Issue{id: issue_id, branch_name: "symphony/octo-app-#{number}", state: "Building", native_ref: %{repository: "octo/app", project_status: "Building"}}
    task = %{"issue_id" => issue_id, "generation" => 1, "phase" => "build", "attempts" => %{"build" => 1}}

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "build", 1)

    {:ok, remote_status} = Agent.start_link(fn -> "Ready" end)
    test_process = self()

    request_fun = fn query, _variables, _settings ->
      if query =~ "updateProjectV2ItemFieldValue" do
        send(test_process, :project_status_write_attempted)
        Agent.update(remote_status, fn _status -> "Building" end)
        {:ok, %{status: 200, body: %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_#{number}"}}}}}}
      else
        status = Agent.get(remote_status, & &1)
        {:ok, %{status: 200, body: project_response([issue_item("octo/app", number, status)])}}
      end
    end

    context = %{
      issue: issue,
      lane: :build,
      generation: 1,
      attempt: 1,
      task: task
    }

    assert {:error, :github_human_decision_changed} =
             Client.agent_operation(issue, context, "claim", %{},
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )

    refute_received :project_status_write_attempted
    assert Agent.get(remote_status, & &1) == "Ready"
  end

  test "Build rejects a malformed PR description before the Projects handoff can write" do
    alias SymphonyElixir.Pipeline.Store

    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-project-pr-body-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    issue = %Issue{
      id: "octo/app#42",
      branch_name: "symphony/octo-app-42",
      state: "Building",
      url: "https://github.com/octo/app/issues/42",
      native_ref: %{repository: "octo/app", project_status: "Building"}
    }

    context = %{issue: issue, lane: :build, generation: 1, attempt: 1, task: %{"branch" => issue.branch_name}}
    assert :ok = Store.save_task(%{"issue_id" => issue.id, "generation" => 1, "phase" => "build", "attempts" => %{"build" => 1}})
    assert :ok = Store.begin_phase(issue.id, 1, "build", 1)

    report = %{
      "outcome" => "ready",
      "summary" => "Build completed.",
      "pull_request_body" => "A body that does not follow the PR template.",
      "sha" => String.duplicate("a", 40)
    }

    comment = "## Build report\n\n<!-- symphony:report:json\n#{Jason.encode!(report, pretty: true)}\n-->"

    assert {:error, :invalid_github_pull_request_body} =
             Client.agent_operation(
               issue,
               context,
               "handoff",
               %{"outcome" => "ready", "report" => report, "body" => comment},
               tracker_settings: tracker_settings(),
               projects_request: fn _query, _variables, _settings -> flunk("invalid PR bodies must fail before GitHub writes") end
             )
  end

  test "Build handoff returns the validated PR body in its evidence" do
    number = 57
    issue_id = "octo/app##{number}"
    sha = String.duplicate("a", 40)
    branch = "symphony/octo-app-#{number}"
    root = Path.join(System.tmp_dir!(), "symphony-project-build-evidence-#{System.unique_integer([:positive])}")
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    issue = %Issue{
      id: issue_id,
      identifier: issue_id,
      title: "Persist Build evidence",
      branch_name: branch,
      state: "Building",
      url: "https://github.com/octo/app/issues/#{number}",
      native_ref: %{
        repository: "octo/app",
        project_status: "Building",
        base_branch: "main",
        issue_node_id: "I_issue_#{number}"
      }
    }

    task = %{"branch" => branch, "base_branch" => "main", "required_checks" => ["true"]}
    assert :ok = Store.save_task(%{"issue_id" => issue.id, "generation" => 1, "phase" => "build", "attempts" => %{"build" => 1}})
    assert :ok = Store.begin_phase(issue.id, 1, "build", 1)
    {:ok, remote} = Agent.start_link(fn -> %{status: "Building"} end)

    request_fun = fn query, variables, _settings ->
      Agent.get_and_update(remote, fn data ->
        cond do
          query =~ "SymphonyProject(" ->
            {{:ok, %{status: 200, body: project_response([issue_item("octo/app", number, data.status)])}}, data}

          query =~ "SymphonyPipelineDelivery" ->
            body = %{"data" => %{"repository" => %{"ref" => %{"name" => branch, "target" => %{"oid" => sha}}}}}
            {{:ok, %{status: 200, body: body}}, data}

          query =~ "SymphonyPipelinePullRequest" ->
            body = %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => []}}}}
            {{:ok, %{status: 200, body: body}}, data}

          query =~ "SymphonyPipelineRepository" ->
            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"id" => "R_octopus"}}}}}, data}

          query =~ "createPullRequest" ->
            pr = %{
              "id" => "PR_#{number}",
              "number" => number,
              "url" => "https://github.com/octo/app/pull/#{number}",
              "state" => "OPEN",
              "isDraft" => true,
              "mergedAt" => nil,
              "baseRefName" => "main",
              "headRefName" => branch,
              "headRefOid" => sha,
              "body" => variables["input"]["body"]
            }

            {{:ok, %{status: 200, body: %{"data" => %{"createPullRequest" => %{"pullRequest" => pr}}}}}, data}

          query =~ "SymphonyPipelineReportComments" ->
            comments = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
            body = %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}
            {{:ok, %{status: 200, body: body}}, data}

          query =~ "SymphonyAddIssueComment" ->
            comment = %{"id" => "IC_build", "url" => "https://github.com/octo/app/issues/#{number}#issuecomment-1"}
            body = %{"data" => %{"addComment" => %{"commentEdge" => %{"node" => comment}}}}
            {{:ok, %{status: 200, body: body}}, data}

          query =~ "updateProjectV2ItemFieldValue" ->
            body = %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_#{number}"}}}}
            {{:ok, %{status: 200, body: body}}, %{data | status: "QA"}}

          true ->
            flunk("unexpected GitHub Projects query: #{query}")
        end
      end)
    end

    body = """
    Fixes ##{number}

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
    """

    report = %{
      "outcome" => "ready",
      "summary" => "Build completed.",
      "pull_request_body" => body,
      "criteria" => [],
      "changes" => [],
      "checks" => [],
      "risks" => [],
      "next_step" => "Continue to QA.",
      "sha" => sha
    }

    markdown = "## Build report\n\nBuild completed.\n\n<!-- symphony:report:json\n#{Jason.encode!(report, pretty: true)}\n-->"

    assert {:ok, evidence} =
             Client.agent_operation(
               issue,
               %{issue: issue, lane: :build, generation: 1, attempt: 1, task: task},
               "handoff",
               %{"outcome" => "ready", "report" => report, "body" => markdown},
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )

    assert evidence["pull_request_body"] == body
  end

  test "Finalize recovers and verifies the merged PR before closing the issue and moving it to Done" do
    alias SymphonyElixir.Pipeline.Store

    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-project-finalize-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    number = System.unique_integer([:positive])
    issue_id = "octo/app##{number}"
    sha = String.duplicate("a", 40)

    issue = %Issue{
      id: issue_id,
      identifier: issue_id,
      branch_name: "symphony/octo-app-#{number}",
      state: "Human Review",
      native_ref: %{repository: "octo/app", base_branch: "main", issue_node_id: "I_issue_#{number}"}
    }

    task = %{"issue_id" => issue_id, "generation" => 1, "phase" => "finalize", "attempts" => %{"finalize" => 1}, "branch" => issue.branch_name, "base_branch" => "main", "current_sha" => sha}

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "finalize", 1)

    merged_pr = %{
      "id" => "PR_pipeline",
      "number" => 107,
      "url" => "https://github.com/octo/app/pull/107",
      "state" => "MERGED",
      "isDraft" => false,
      "mergedAt" => "2026-10-21T09:00:00Z",
      "baseRefName" => "main",
      "baseRefOid" => "base-sha",
      "headRefName" => issue.branch_name,
      "headRefOid" => sha,
      "reviewDecision" => nil,
      "body" => "delivery"
    }

    report = %{"outcome" => "merged", "summary" => "Merge verified.", "sha" => sha}
    markdown = "## Finalize report\n\nMerge verified.\n\n<!-- symphony:report:json\n#{Jason.encode!(report, pretty: true)}\n-->"

    {:ok, remote} = Agent.start_link(fn -> %{status: "Human Review", issue_state: "OPEN", events: []} end)

    request_fun = fn query, _variables, _settings ->
      Agent.get_and_update(remote, fn data ->
        cond do
          query =~ "SymphonyProject(" ->
            issue_item = issue_item("octo/app", number, data.status, data.issue_state)
            {{:ok, %{status: 200, body: project_response([issue_item])}}, data}

          query =~ "SymphonyPipelinePullRequest" ->
            events = [:pull_request_read | data.events]
            body = %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => [merged_pr]}}}}
            {{:ok, %{status: 200, body: body}}, %{data | events: events}}

          query =~ "SymphonyPipelineCloseIssue" ->
            assert Enum.count(data.events, &(&1 == :pull_request_read)) >= 2
            events = [:issue_closed | data.events]
            body = %{"data" => %{"closeIssue" => %{"issue" => %{"id" => "I_issue_#{number}", "state" => "CLOSED", "url" => issue.url}}}}
            {{:ok, %{status: 200, body: body}}, %{data | issue_state: "CLOSED", events: events}}

          query =~ "SymphonyPipelineReportComments" ->
            comments = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}}}, data}

          query =~ "SymphonyAddIssueComment" ->
            comment = %{"id" => "IC_agent", "url" => "https://github.com/octo/app/issues/#{number}#issuecomment-1"}
            body = %{"data" => %{"addComment" => %{"commentEdge" => %{"node" => comment}}}}
            {{:ok, %{status: 200, body: body}}, data}

          query =~ "SymphonySetProjectStatus" ->
            body = %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_#{number}"}}}}
            {{:ok, %{status: 200, body: body}}, %{data | status: "Done"}}

          true ->
            flunk("unexpected GitHub Projects query: #{query}")
        end
      end)
    end

    context = %{issue: issue, lane: :finalize, generation: 1, attempt: 1, task: task}

    assert {:ok, result} =
             Client.agent_operation(
               issue,
               context,
               "handoff",
               %{
                 "outcome" => "merged",
                 "report" => report,
                 "body" => markdown
               },
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )

    assert result["closed_issue"]["state"] == "CLOSED"
    assert result["pull_request"]["merged"]
    assert result["pull_request"]["head_sha"] == sha
    assert result["project_item"]["status"] == "Done"
    assert Enum.take(Agent.get(remote, &Enum.reverse(&1.events)), 3) == [:pull_request_read, :pull_request_read, :issue_closed]
  end

  test "merge gate merges only with approved checks and current SHA and base evidence" do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-project-merge-gate-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    {result, queries} = run_merge_gate(%{})
    expected_sha = String.duplicate("a", 40)
    assert {:ok, %{"outcome" => "merged", "sha" => ^expected_sha, "pull_request" => %{"head_sha" => ^expected_sha, "merged" => true}}} = result
    assert Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))
    assert Enum.any?(queries, &(&1 =~ "SymphonyPipelinePullRequest"))

    {without_github_checks, queries} = run_merge_gate(%{github_check_rollup: nil})
    assert {:ok, %{"outcome" => "merged", "pull_request" => %{"merged" => true}}} = without_github_checks
    assert Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))

    {already_merged, queries} = run_merge_gate(%{pr_state: "MERGED"})
    assert {:ok, %{"outcome" => "merged", "pull_request" => %{"merged" => true}}} = already_merged
    refute Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))

    for {scenario, expected_error} <- [
          {%{host_check_status: "failed"}, :host_checks_not_verified},
          {%{github_check_status: "FAILURE"}, :required_github_checks_not_passed},
          {%{pr_head_sha: String.duplicate("b", 40)}, :pull_request_head_sha_mismatch},
          {%{pr_base_sha: "stale-base"}, :pull_request_base_sha_mismatch},
          {%{current_base_sha: nil, pr_base_sha: nil}, :pull_request_base_sha_unavailable}
        ] do
      {result, queries} = run_merge_gate(scenario)
      assert result == {:error, expected_error}
      refute Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))
    end

    {result, queries} = run_merge_gate(%{provider_error: true})
    assert {:error, {:github_projects_api_error, _}} = result
    refute Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))
  end

  test "Review cannot hand off unresolved prior findings to Human Review" do
    finding = %{"id" => "QA-1", "reproduction" => "Run the failing case.", "criterion" => "The acceptance criterion passes."}
    context = %{task: %{"prior_findings" => [finding]}}
    report = %{"outcome" => "passed", "findings" => [], "resolutions" => []}

    assert %{"outcome" => "changes_requested", "findings" => [^finding]} =
             Client.normalize_agent_report_for_test(report, "review", context)

    assert %{"outcome" => "passed", "findings" => []} =
             Client.normalize_agent_report_for_test(%{report | "resolutions" => [finding["id"]]}, "review", context)

    assert %{"outcome" => "passed", "findings" => []} =
             Client.normalize_agent_report_for_test(
               %{report | "resolutions" => [finding["id"] <> " — resolved: the check passed after the fix."]},
               "review",
               context
             )
  end

  test "Build report persists the task branch for later phases" do
    report = %{"outcome" => "ready", "sha" => String.duplicate("a", 40)}

    task = %{
      "branch" => "symphony/issue-40",
      "base_branch" => "main",
      "required_checks" => ["make -C elixir all"]
    }

    assert %{
             "branch" => "symphony/issue-40",
             "base_branch" => "main",
             "required_checks" => ["make -C elixir all"]
           } = Client.normalize_agent_report_for_test(report, "build", %{task: task})
  end

  test "Review report persists merge metadata for Finalize" do
    sha = String.duplicate("a", 40)
    task = %{"branch" => "symphony/issue-40", "base_branch" => "main", "pr_number" => 55, "current_sha" => sha}

    assert %{
             "branch" => "symphony/issue-40",
             "base_branch" => "main",
             "pr_number" => 55,
             "sha" => ^sha
           } =
             Client.normalize_agent_report_for_test(
               %{"outcome" => "passed", "findings" => []},
               "review",
               %{task: task}
             )
  end

  test "Review reads QA evidence from the issue workpad and phase reports" do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-project-read-workpad-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    number = System.unique_integer([:positive])
    issue_id = "octo/app##{number}"
    sha = String.duplicate("a", 40)
    old_sha = String.duplicate("b", 40)
    agent_login = "symphony[bot]"
    workpad = "<!-- symphony:workpad:start -->\n## Codex Workpad\n\n### QA\n- Check passed on #{sha}.\n<!-- symphony:workpad:end -->"

    qa_report = %{
      "outcome" => "passed",
      "sha" => sha,
      "checks" => [%{"name" => "make -C elixir all", "status" => "passed", "evidence" => "Host exit status 0 on #{sha}."}]
    }

    prior_qa_report = %{
      "outcome" => "changes_requested",
      "sha" => sha,
      "findings" => [%{"id" => "QA-1", "reproduction" => "Run the check.", "criterion" => "The result passes."}]
    }

    first_page_comments = [
      %{
        "id" => "workpad-comment",
        "url" => "https://github.com/octo/app/issues/#{number}#workpad",
        "body" => workpad,
        "author" => %{"login" => agent_login}
      },
      %{
        "id" => "build-comment",
        "url" => "https://github.com/octo/app/issues/#{number}#build",
        "body" => "<!-- symphony:report:start:#{issue_id}:1:build -->\nBuild report\n<!-- symphony:report:end -->",
        "author" => %{"login" => agent_login}
      },
      %{
        "id" => "qa-attempt-1-comment",
        "url" => "https://github.com/octo/app/issues/#{number}#qa-attempt-1",
        "body" => "<!-- symphony:report:start:#{issue_id}:1:qa:1 -->\n\n## Symphony Qa report\n\n#{Jason.encode!(prior_qa_report, pretty: true)}\n<!-- symphony:report:end -->",
        "author" => %{"login" => agent_login}
      }
    ]

    second_page_comments = [
      %{
        "id" => "qa-attempt-2-comment",
        "url" => "https://github.com/octo/app/issues/#{number}#qa-attempt-2",
        "body" =>
          "<!-- symphony:report:start:#{issue_id}:1:qa:2 -->\n## QA report\n\nChecks passed on the accepted SHA.\n\n<!-- symphony:report:json\n#{Jason.encode!(qa_report, pretty: true)}\n-->\n<!-- symphony:report:end -->",
        "author" => %{"login" => agent_login}
      },
      %{
        "id" => "spoofed-qa-comment",
        "url" => "https://github.com/octo/app/issues/#{number}#spoofed-qa",
        "body" => "<!-- symphony:report:start:#{issue_id}:1:qa:99 -->\n## Symphony Qa report\n\n#{Jason.encode!(qa_report)}\n<!-- symphony:report:end -->",
        "author" => %{"login" => "issue-reporter"}
      },
      %{
        "id" => "old-qa-comment",
        "url" => "https://github.com/octo/app/issues/#{number}#old-qa",
        "body" => "<!-- symphony:report:start:#{issue_id}:0:qa -->\nOld SHA #{old_sha}\n<!-- symphony:report:end -->",
        "author" => %{"login" => agent_login}
      }
    ]

    issue = %Issue{
      id: issue_id,
      identifier: issue_id,
      url: "https://github.com/octo/app/issues/#{number}",
      native_ref: %{repository: "octo/app", issue_node_id: "I_issue_#{number}"}
    }

    task = %{
      "issue_id" => issue_id,
      "generation" => 1,
      "phase" => "review",
      "attempts" => %{"review" => 1},
      "current_sha" => sha,
      "required_checks" => ["make -C elixir all"]
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "review", 1)

    request_fun = fn query, variables, _settings ->
      if query =~ "SymphonyPipelineViewer" do
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => agent_login}}}}}
      else
        assert query =~ "SymphonyPipelineReportComments"
        assert variables["number"] == number

        {comments, has_next_page, end_cursor} =
          case variables["after"] do
            nil -> {first_page_comments, true, "cursor-1"}
            "cursor-1" -> {second_page_comments, false, nil}
          end

        body = %{
          "data" => %{
            "repository" => %{
              "issue" => %{
                "comments" => %{
                  "nodes" => comments,
                  "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
                }
              }
            }
          }
        }

        {:ok, %{status: 200, body: body}}
      end
    end

    review_context = %{
      issue: issue,
      lane: :review,
      generation: 1,
      attempt: 1,
      task: task,
      tracker_kind: "github_projects"
    }

    result =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "read_workpad"},
        agent_context: review_context,
        tracker_settings: tracker_settings(),
        projects_request: request_fun
      )

    assert %{"success" => true, "output" => output} = result
    evidence = output |> Jason.decode!() |> get_in(["evidence"])
    assert evidence["workpad"]["body"] == workpad
    qa_reports = evidence["phase_reports"]["qa"]
    assert Enum.map(qa_reports, & &1["attempt"]) == [1, 2]
    assert hd(qa_reports)["body"] =~ "QA-1"
    assert List.last(qa_reports)["body"] =~ "Host exit status 0 on #{sha}"
    assert evidence["report_context"]["task"]["current_sha"] == sha
    refute Enum.any?(qa_reports, &String.contains?(&1["body"], old_sha))

    legacy_comments =
      (first_page_comments ++ second_page_comments)
      |> Enum.map(fn
        %{"id" => "qa-attempt-2-comment"} = comment ->
          Map.put(comment, "body", "<!-- symphony:report:start:#{issue_id}:1:qa:2 -->\n\n## Symphony Qa report\n\n#{Jason.encode!(qa_report, pretty: true)}\n<!-- symphony:report:end -->")

        comment ->
          comment
      end)

    legacy_request_fun = fn query, _variables, _settings ->
      if query =~ "SymphonyPipelineViewer" do
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => agent_login}}}}}
      else
        comments = %{"nodes" => legacy_comments, "pageInfo" => %{"hasNextPage" => false}}
        body = %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}
        {:ok, %{status: 200, body: body}}
      end
    end

    assert {:ok, _legacy_evidence} =
             Client.agent_operation(
               issue,
               review_context,
               "read_workpad",
               %{},
               tracker_settings: tracker_settings(),
               projects_request: legacy_request_fun
             )

    report_marker = "<!-- symphony:report:start:#{issue_id}:1:qa:3 -->"

    malformed_report_comments = fn report_body ->
      comment = %{
        "id" => "malformed-qa-report",
        "url" => "https://github.com/octo/app/issues/#{number}#malformed-qa-report",
        "body" => "#{report_marker}\n#{report_body}\n<!-- symphony:report:end -->",
        "author" => %{"login" => agent_login}
      }

      fn query, _variables, _settings ->
        response_body =
          if query =~ "SymphonyPipelineViewer" do
            %{"data" => %{"viewer" => %{"login" => agent_login}}}
          else
            comments = %{"nodes" => [comment], "pageInfo" => %{"hasNextPage" => false}}
            %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}
          end

        {:ok, %{status: 200, body: response_body}}
      end
    end

    for report_body <- [
          "not a JSON report",
          "<!-- symphony:report:json\nnot JSON\n-->",
          "<!-- symphony:report:json\n{}\n-->\n<!-- symphony:report:json\n{}\n-->"
        ] do
      malformed =
        AgentTool.execute(
          "github_workflow",
          %{"operation" => "read_workpad"},
          agent_context: review_context,
          tracker_settings: tracker_settings(),
          projects_request: malformed_report_comments.(report_body)
        )

      refute malformed["success"]
      assert Jason.decode!(malformed["output"])["error"]["reason"] == ":qa_evidence_unavailable"
    end

    stale_report =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "read_workpad"},
        agent_context: %{review_context | task: Map.put(task, "current_sha", old_sha)},
        tracker_settings: tracker_settings(),
        projects_request: request_fun
      )

    assert %{"success" => false} = stale_report
    assert Jason.decode!(stale_report["output"])["error"]["reason"] == ":qa_evidence_unavailable"

    assert %{"success" => false} =
             AgentTool.execute(
               "github_workflow",
               %{"operation" => "read_workpad"},
               agent_context: %{review_context | task: Map.put(task, "required_checks", ["mix test"])},
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )
  end

  test "QA findings turn a passed report into a correction handoff" do
    finding = %{"id" => "QA-2", "reproduction" => "Run the failing check.", "criterion" => "The acceptance criterion passes."}

    report = %{
      "outcome" => "passed",
      "summary" => "QA passed.",
      "findings" => [finding],
      "next_step" => "Continue to Review."
    }

    context = %{
      task: %{"required_checks" => ["mix test"]},
      host_checks: [%{"name" => "mix test", "status" => "passed", "evidence" => "exit status 0"}]
    }

    assert %{
             "outcome" => "changes_requested",
             "summary" => "QA reported findings that need correction.",
             "next_step" => "Fix the findings and submit a new Build delivery.",
             "findings" => [^finding]
           } = Client.normalize_agent_report_for_test(report, "qa", context)
  end

  test "QA-generated report values follow the issue locale" do
    finding = %{"id" => "QA-3", "reproduction" => "Ejecutar la comprobación fallida.", "criterion" => "La comprobación pasa."}
    base = %{report_locale: :es, task: %{"required_checks" => ["mix test"]}}
    failed = Map.put(base, :host_checks, [%{"name" => "mix test", "status" => "failed"}])
    unavailable = Map.put(base, :host_checks, [%{"name" => "mix test", "status" => "unavailable"}])
    passed = Map.put(base, :host_checks, [%{"name" => "mix test", "status" => "passed", "evidence" => "exit status 0"}])

    assert %{
             "outcome" => "changes_requested",
             "summary" => "Falló alguna comprobación requerida o falta evidencia para confirmarla."
           } = Client.normalize_agent_report_for_test(%{"outcome" => "passed"}, "qa", failed)

    assert %{
             "outcome" => "blocked",
             "reason" => "Symphony no pudo ejecutar todas las comprobaciones requeridas."
           } = Client.normalize_agent_report_for_test(%{"outcome" => "passed"}, "qa", unavailable)

    assert %{
             "outcome" => "changes_requested",
             "summary" => "QA encontró hallazgos que requieren corrección.",
             "next_step" => "Corrige los hallazgos y vuelve a entregar el trabajo en Build."
           } = Client.normalize_agent_report_for_test(%{"outcome" => "passed", "findings" => [finding]}, "qa", passed)
  end

  test "QA defects return the Project item to Building" do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-project-qa-defects-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    number = System.unique_integer([:positive])
    issue_id = "octo/app##{number}"
    sha = String.duplicate("a", 40)

    issue = %Issue{
      id: issue_id,
      identifier: issue_id,
      url: "https://github.com/octo/app/issues/#{number}",
      branch_name: "symphony/octo-app-#{number}",
      state: "Ready",
      native_ref: %{repository: "octo/app", base_branch: "main", project_status: "Ready", issue_node_id: "I_issue_#{number}"}
    }

    task = %{
      "issue_id" => issue_id,
      "generation" => 1,
      "phase" => "qa",
      "attempts" => %{"qa" => 1},
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "current_sha" => sha,
      "required_checks" => ["mix test"]
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "qa", 1)

    {:ok, remote} = Agent.start_link(fn -> %{status: "Ready", report_body: nil} end)

    request_fun = fn query, variables, _settings ->
      Agent.get_and_update(remote, fn data ->
        cond do
          query =~ "SymphonyProject(" ->
            item = issue_item("octo/app", number, data.status)
            {{:ok, %{status: 200, body: project_response([item])}}, data}

          query =~ "SymphonyPipelinePullRequest" ->
            pr = %{
              "id" => "PR_#{number}",
              "number" => number,
              "url" => "https://github.com/octo/app/pull/#{number}",
              "state" => "OPEN",
              "isDraft" => true,
              "mergedAt" => nil,
              "baseRefName" => "main",
              "headRefName" => issue.branch_name,
              "headRefOid" => sha,
              "body" => ""
            }

            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => [pr]}}}}}}, data}

          query =~ "SymphonyPipelineViewer" ->
            {{:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "agent"}}}}}, data}

          query =~ "SymphonyPipelineReportComments" ->
            comments = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}}}, data}

          query =~ "SymphonyAddIssueComment" ->
            comment = %{"id" => "IC_qa", "url" => "https://github.com/octo/app/issues/#{number}#issuecomment-1"}
            body = %{"data" => %{"addComment" => %{"commentEdge" => %{"node" => comment}}}}
            {{:ok, %{status: 200, body: body}}, %{data | report_body: variables["body"]}}

          query =~ "SymphonySetProjectStatus" ->
            body = %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_#{number}"}}}}
            status = %{"option-qa" => "QA", "option-building" => "Building"}[variables["optionId"]]
            {{:ok, %{status: 200, body: body}}, %{data | status: status}}

          true ->
            flunk("unexpected GitHub Projects query: #{query}")
        end
      end)
    end

    finding = %{"id" => "QA-1", "reproduction" => "Run the failing check.", "criterion" => "The acceptance criterion passes."}

    report = %{
      "outcome" => "defects_found",
      "summary" => "QA found a defect.",
      "findings" => [finding],
      "next_step" => "Fix the defect.",
      "sha" => sha,
      "checks" => [%{"name" => "mix test", "status" => "failed", "evidence" => "stale agent result"}]
    }

    markdown = "## QA report\n\nQA found a defect.\n\n<!-- symphony:report:json\n#{Jason.encode!(report, pretty: true)}\n-->"

    context = %{
      issue: issue,
      lane: :qa,
      generation: 1,
      attempt: 1,
      task: task,
      host_checks: [%{"name" => "mix test", "status" => "passed", "evidence" => "exit status 0"}],
      tracker_kind: "github_projects"
    }

    claim =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "claim"},
        agent_context: context,
        tracker_settings: tracker_settings(),
        projects_request: request_fun
      )

    assert claim["success"], claim["output"]
    assert claim["evidence"]["project_item"]["status"] == "QA"
    assert Agent.get(remote, & &1.status) == "QA"

    handoff =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "handoff", "outcome" => "defects_found", "report" => report, "body" => markdown},
        agent_context: context,
        tracker_settings: tracker_settings(),
        projects_request: request_fun
      )

    assert handoff["success"], handoff["output"]
    assert handoff["evidence"]["project_item"]["status"] == "Building"

    assert Agent.get(remote, & &1.status) == "Building"

    stored_comment = Agent.get(remote, & &1.report_body)
    assert stored_comment =~ "<!-- symphony:report:start:#{issue_id}:1:qa:1 -->"
    assert stored_comment =~ "## QA report\n\nQA found a defect.\n\n"
    assert {:ok, stored_report} = AgentReport.decode_comment(stored_comment)
    assert stored_report["checks"] == context.host_checks

    workpad_result =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "read_workpad"},
        agent_context: context,
        tracker_settings: tracker_settings(),
        projects_request: request_fun
      )

    assert workpad_result["success"], workpad_result["output"]
    workpad = workpad_result["evidence"]
    assert workpad["report_context"]["task"]["required_checks"] == ["mix test"]
    assert workpad["report_context"]["host_checks"] == context.host_checks
    assert workpad["report_context"]["qa_text"]["checks_failed"] == "One or more required host checks failed or were missing."

    visible_json =
      AgentTool.execute(
        "github_workflow",
        %{
          "operation" => "handoff",
          "outcome" => "defects_found",
          "report" => report,
          "body" => "## QA report\n\n#{Jason.encode!(report, pretty: true)}\n\n<!-- symphony:report:json\n#{Jason.encode!(report, pretty: true)}\n-->"
        },
        agent_context: context,
        tracker_settings: tracker_settings(),
        projects_request: fn _query, _variables, _settings -> flunk("visible report JSON must fail before GitHub writes") end
      )

    refute visible_json["success"]
    assert Jason.decode!(visible_json["output"])["error"]["reason"] == ":visible_github_agent_report_json"

    invalid_handoff = fn body, current_report ->
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "handoff", "outcome" => "defects_found", "report" => current_report, "body" => body},
        agent_context: context,
        tracker_settings: tracker_settings(),
        projects_request: fn _query, _variables, _settings -> flunk("invalid reports must fail before GitHub writes") end
      )
    end

    unsafe_report = Map.put(report, "summary", "Marker --> text must not reveal the report.")
    unsafe_json = Jason.encode!(unsafe_report, pretty: true)

    for {body, current_report, reason} <- [
          {nil, report, :invalid_github_agent_report_body},
          {"## QA report\n\nText only.", report, :missing_github_agent_report_json},
          {markdown <> "\n<!-- symphony:report:json\n#{Jason.encode!(report, pretty: true)}\n-->", report, :invalid_github_agent_report_json}
        ] do
      invalid = invalid_handoff.(body, current_report)

      refute invalid["success"]
      assert Jason.decode!(invalid["output"])["error"]["reason"] == ":#{reason}"
    end

    unsafe_body = "## QA report\n\n<!-- symphony:report:json\n#{unsafe_json}\n-->"
    assert {:error, :unsafe_github_agent_report_json} = AgentReport.validate_body(unsafe_body, unsafe_report)
    assert {:ok, safe_body} = AgentReport.normalize_body(unsafe_body, unsafe_report)
    assert safe_body =~ "--\\u003e"
    assert :ok = AgentReport.validate_body(safe_body, unsafe_report)
    assert {:error, :invalid_github_agent_report_body} = AgentReport.validate_body(nil, report)
    assert {:error, :invalid_github_agent_report_body} = AgentReport.normalize_body(nil, report)

    duplicate_blocks = "<!-- symphony:report:json\n{}\n-->\n<!-- symphony:report:json\n{}\n-->"
    assert {:error, :missing_github_agent_report_json} = AgentReport.validate_body("plain text", report)
    assert {:error, :invalid_github_agent_report_json} = AgentReport.validate_body(duplicate_blocks, report)

    assert {:error, :invalid_github_agent_report_json} =
             AgentReport.normalize_body(unsafe_body, Map.put(unsafe_report, "unsupported", self()))
  end

  test "Review defects return the Project item to Building" do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-project-review-defects-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    number = System.unique_integer([:positive])
    issue_id = "octo/app##{number}"
    sha = String.duplicate("b", 40)

    issue = %Issue{
      id: issue_id,
      identifier: issue_id,
      url: "https://github.com/octo/app/issues/#{number}",
      branch_name: "symphony/octo-app-#{number}",
      state: "Ready",
      native_ref: %{
        repository: "octo/app",
        base_branch: "main",
        project_status: "Ready",
        issue_node_id: "I_issue_#{number}"
      }
    }

    task = %{
      "issue_id" => issue_id,
      "generation" => 1,
      "phase" => "review",
      "attempts" => %{"review" => 1},
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "current_sha" => sha
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "review", 1)
    {:ok, remote} = Agent.start_link(fn -> %{status: "Ready", draft: false} end)

    request_fun = fn query, variables, _settings ->
      Agent.get_and_update(remote, fn data ->
        cond do
          query =~ "SymphonyProject(" ->
            {{:ok, %{status: 200, body: project_response([issue_item("octo/app", number, data.status)])}}, data}

          query =~ "SymphonyPipelinePullRequest" ->
            pr = %{
              "id" => "PR_#{number}",
              "number" => number,
              "url" => "https://github.com/octo/app/pull/#{number}",
              "state" => "OPEN",
              "isDraft" => data.draft,
              "mergedAt" => nil,
              "baseRefName" => "main",
              "headRefName" => issue.branch_name,
              "headRefOid" => sha,
              "body" => ""
            }

            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => [pr]}}}}}}, data}

          query =~ "SymphonyPipelineReportComments" ->
            comments = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}}}, data}

          query =~ "SymphonyAddIssueComment" ->
            comment = %{"id" => "IC_review", "url" => "https://github.com/octo/app/issues/#{number}#issuecomment-1"}
            body = %{"data" => %{"addComment" => %{"commentEdge" => %{"node" => comment}}}}
            {{:ok, %{status: 200, body: body}}, data}

          query =~ "SymphonyConvertPipelinePullRequestToDraft" ->
            pr = %{
              "id" => "PR_#{number}",
              "number" => number,
              "url" => "https://github.com/octo/app/pull/#{number}",
              "state" => "OPEN",
              "isDraft" => true,
              "mergedAt" => nil,
              "baseRefName" => "main",
              "headRefName" => issue.branch_name,
              "headRefOid" => sha
            }

            body = %{"data" => %{"convertPullRequestToDraft" => %{"pullRequest" => pr}}}
            {{:ok, %{status: 200, body: body}}, %{data | draft: true}}

          query =~ "SymphonySetProjectStatus" ->
            body = %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_#{number}"}}}}
            status = %{"option-review" => "Review", "option-building" => "Building"}[variables["optionId"]]
            {{:ok, %{status: 200, body: body}}, %{data | status: status}}

          true ->
            flunk("unexpected GitHub Projects query: #{query}")
        end
      end)
    end

    finding = %{"id" => "REV-1", "reproduction" => "Run the affected path.", "criterion" => "The review criterion passes."}

    report = %{
      "outcome" => "defects_found",
      "summary" => "Review found a defect.",
      "findings" => [finding],
      "resolutions" => [],
      "next_step" => "Fix the finding.",
      "sha" => sha,
      "branch" => issue.branch_name,
      "base_branch" => "main"
    }

    markdown = "## Review report\n\nReview found a defect.\n\n<!-- symphony:report:json\n#{Jason.encode!(report, pretty: true)}\n-->"

    context = %{issue: issue, lane: :review, generation: 1, attempt: 1, task: task, tracker_kind: "github_projects"}

    claim =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "claim"},
        agent_context: context,
        tracker_settings: tracker_settings(),
        projects_request: request_fun
      )

    assert claim["success"], claim["output"]
    assert claim["evidence"]["project_item"]["status"] == "Review"
    assert Agent.get(remote, & &1.status) == "Review"

    assert {:ok,
            %{
              "outcome" => "defects_found",
              "project_item" => %{"status" => "Building"},
              "pull_request" => %{"draft" => true}
            }} =
             Client.agent_operation(
               issue,
               context,
               "handoff",
               %{"outcome" => "defects_found", "report" => report, "body" => markdown},
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )

    assert Agent.get(remote, & &1.status) == "Building"
    assert Agent.get(remote, & &1.draft)
  end

  test "Projects follow-up REST requests use the configured GitHub Enterprise host" do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    previous_req_options = Application.get_env(:req, :default_options)
    root = Path.join(System.tmp_dir!(), "symphony-project-enterprise-follow-up-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))
    owner = self()

    plug = fn conn ->
      send(owner, {:github_rest_request, conn.host, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(503, "{}")
    end

    Application.put_env(:req, :default_options, plug: plug, retry: false)

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      case previous_req_options do
        nil -> Application.delete_env(:req, :default_options)
        options -> Application.put_env(:req, :default_options, options)
      end

      File.rm_rf!(root)
    end)

    issue = %Issue{
      id: "octo/app#42",
      identifier: "octo/app#42",
      url: "https://github.com/octo/app/issues/42",
      native_ref: %{repository: "octo/app"}
    }

    context = %{issue: issue, lane: :individual, generation: 1, attempt: 1, lease_token: "enterprise-agent"}
    assert :ok = Store.begin_agent_lease(issue.id, context.lease_token)

    assert {:error, {:github_follow_up_search_failed, 503}} =
             Client.agent_operation(
               issue,
               context,
               "create_follow_up_issue",
               %{"title" => "Track follow-up", "body" => "Follow-up details"},
               tracker_settings: tracker_settings(%{"graphql_url" => "https://github.enterprise.example/api/graphql"})
             )

    assert_received {:github_rest_request, "github.enterprise.example", "/api/v3/search/issues"}
  end

  test "uncertain follow-up creation searches with the raw marker before linking the existing issue" do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-project-follow-up-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    issue = %Issue{
      id: "octo/app#42",
      identifier: "octo/app#42",
      url: "https://github.com/octo/app/issues/42",
      native_ref: %{repository: "octo/app", issue_node_id: "I_parent"}
    }

    context = %{issue: issue, lane: :individual, generation: 1, attempt: 1, lease_token: "follow-up-agent"}
    assert :ok = Store.begin_agent_lease(issue.id, context.lease_token)

    {:ok, remote} =
      Agent.start_link(fn ->
        %{follow_up: nil, linked?: false, project_added?: false, creates: 0, links: 0, project_adds: 0}
      end)

    github_rest = fn method, path, params, body, _settings ->
      Agent.get_and_update(remote, fn data ->
        case {method, path} do
          {"GET", "/search/issues"} ->
            query = params["q"]
            assert query =~ "repo:octo/app in:body <!-- symphony:follow-up:octo/app#42:1:individual:"
            refute query =~ "%"
            [marker] = Regex.run(~r/<!-- symphony:follow-up:[^>]+-->/, query)

            items =
              if data.follow_up && marker && String.contains?(data.follow_up["body"], marker),
                do: [data.follow_up],
                else: []

            {{:ok, %{status: 200, body: %{"items" => items}}}, data}

          {"POST", "/repos/octo/app/issues"} ->
            follow_up = %{
              "id" => 77,
              "node_id" => "I_issue_43",
              "number" => 43,
              "html_url" => "https://github.com/octo/app/issues/43",
              "url" => "https://api.github.com/repos/octo/app/issues/43",
              "repository" => %{"nameWithOwner" => "octo/app"},
              "body" => body["body"]
            }

            {{:error, :timeout}, %{data | follow_up: follow_up, creates: data.creates + 1}}

          {"GET", "/repos/octo/app/issues/42/sub_issues"} ->
            linked = if data.linked?, do: [data.follow_up], else: []
            {{:ok, %{status: 200, body: linked}}, data}

          {"POST", "/repos/octo/app/issues/42/sub_issues"} ->
            {{:ok, %{status: 201, body: data.follow_up}}, %{data | linked?: true, links: data.links + 1}}
        end
      end)
    end

    projects_request = fn query, variables, _settings ->
      Agent.get_and_update(remote, fn data ->
        cond do
          query =~ "addProjectV2ItemById" ->
            assert variables["contentId"] == "I_issue_43"
            item = %{"id" => "PVTI_follow_up"}
            response = %{status: 200, body: %{"data" => %{"addProjectV2ItemById" => %{"item" => item}}}}
            updated = %{data | project_added?: true, project_adds: data.project_adds + 1}
            {{:ok, response}, updated}

          query =~ "SymphonyProject(" ->
            items = if data.project_added?, do: [issue_item("octo/app", 43, "Ready")], else: []
            {{:ok, %{status: 200, body: project_response(items)}}, data}

          true ->
            flunk("unexpected GitHub Projects query: #{query}")
        end
      end)
    end

    assert {:ok, evidence} =
             Client.agent_operation(
               issue,
               context,
               "create_follow_up_issue",
               %{"title" => "Track follow-up", "body" => "Follow-up details"},
               tracker_settings: tracker_settings(),
               github_rest: github_rest,
               projects_request: projects_request
             )

    assert {:ok, retried_evidence} =
             Client.agent_operation(
               issue,
               %{context | attempt: 2},
               "create_follow_up_issue",
               %{"title" => "Track follow-up", "body" => "Follow-up details"},
               tracker_settings: tracker_settings(),
               github_rest: github_rest,
               projects_request: projects_request
             )

    assert evidence["id"] == "octo/app#43"
    assert evidence["linked"]
    assert evidence["project_item"] == %{"id" => "PVTI_43", "status" => "Ready"}
    assert retried_evidence == evidence
    assert Agent.get(remote, & &1.linked?)
    assert Agent.get(remote, & &1.project_added?)
    assert Agent.get(remote, & &1.creates) == 1
    assert Agent.get(remote, & &1.links) == 1
    assert Agent.get(remote, & &1.project_adds) == 1
    assert :ok = Store.end_agent_lease(issue.id, context.lease_token)
  end

  test "Projects configuration reports missing owner without exposing a token" do
    assert {:error, {:invalid_github_projects_settings, :missing_owner}} =
             Adapter.validate_config(%{
               kind: "github_projects",
               provider: %{"token" => "must-not-be-logged"}
             })
  end

  test "Projects configuration requires auth, status-only routing, and requeue-safe terminal states" do
    settings = tracker_settings()
    missing_token = tracker_settings(%{"token" => ""})

    assert {:error, {:invalid_github_projects_settings, :missing_token}} =
             Client.validate_settings(missing_token)

    assert {:error, {:invalid_github_projects_settings, :required_labels_not_supported}} =
             Client.validate_settings(%{settings | required_labels: ["ready-for-agent"]})

    assert {:error, {:invalid_github_projects_settings, :terminal_states_must_include_closed_and_dropped}} =
             Client.validate_settings(%{settings | terminal_states: ["closed", "Done"]})
  end

  test "legacy Projects status mappings do not affect canonical adaptation" do
    legacy_statuses = %{
      "backlog" => "Ideas",
      "ready" => "Queued",
      "building" => "Implementing",
      "qa" => "Verifying",
      "review" => "Auditing",
      "human_review" => "Awaiting Human",
      "blocked" => "Needs Help",
      "done" => "Integrated",
      "dropped" => "Discarded"
    }

    settings =
      tracker_settings(%{
        "status_field" => "Workflow",
        "status_values" => legacy_statuses,
        "repositories" => [
          %{"repository" => "octo/app", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["true"]}
        ]
      })
      |> Map.merge(%{
        active_states: ["Ready", "Building", "QA", "Review", "Human Review"],
        terminal_states: ["closed", "Dropped"]
      })

    response = project_response([issue_item("octo/app", 7, "Ready")])

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["Ready"], settings, fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: response}}
             end)

    assert issue.state == "Ready"
    assert issue.native_ref.project_status == "Ready"
    refute Map.has_key?(issue.native_ref, :status_values)
  end

  test "created pipeline PR includes the Build report body" do
    settings = tracker_settings(%{"repositories" => [%{"repository" => "octo/app", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["true"]}]})
    issue = %SymphonyElixir.Tracker.Issue{id: "octo/app#7", branch_name: "symphony/octo-app-7", native_ref: %{repository: "octo/app"}}
    body = "<!-- symphony:delivery -->\n\nFixes octo/app#7\n\n## Summary\nImplemented it."
    pr = pipeline_pr(issue, body)

    request_fun = fn query, variables, _settings ->
      cond do
        query =~ "pullRequests" ->
          {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => []}}}}}}

        query =~ "SymphonyPipelineRepository" ->
          {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"id" => "R_octopus"}}}}}

        query =~ "createPullRequest" ->
          assert variables["input"]["body"] == body
          {:ok, %{status: 200, body: %{"data" => %{"createPullRequest" => %{"pullRequest" => pr}}}}}
      end
    end

    attrs = %{branch: issue.branch_name, base: "main", sha: "sha-seven", body: body}
    assert {:ok, %{body: ^body}} = Client.upsert_pull_request_for_test(issue, attrs, settings, request_fun)
  end

  test "pipeline PR creation requires an authored body" do
    settings = tracker_settings()
    issue = %SymphonyElixir.Tracker.Issue{id: "octo/app#7", branch_name: "symphony/octo-app-7", native_ref: %{repository: "octo/app"}}

    request_fun = fn query, _variables, _settings ->
      assert query =~ "pullRequests"
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => []}}}}}}
    end

    assert {:error, :github_pull_request_body_required} =
             Client.upsert_pull_request_for_test(
               issue,
               %{branch: issue.branch_name, base: "main"},
               settings,
               request_fun
             )
  end

  test "pipeline PR lookup includes merged pull requests" do
    settings = tracker_settings()

    issue = %SymphonyElixir.Tracker.Issue{
      id: "octo/app#7",
      branch_name: "symphony/octo-app-7",
      native_ref: %{repository: "octo/app", base_branch: "main"}
    }

    merged_pr =
      pipeline_pr(issue, "delivery")
      |> Map.merge(%{"state" => "MERGED", "isDraft" => false, "mergedAt" => "2026-10-21T09:00:00Z"})

    request_fun = fn query, variables, _settings ->
      assert query =~ "states: [OPEN, CLOSED, MERGED]"
      assert variables == %{"owner" => "octo", "name" => "app", "branch" => issue.branch_name, "base" => "main"}

      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => [merged_pr]}}}}}}
    end

    assert {:ok, %{merged: true, state: "MERGED", base: "main"}} =
             Client.pull_request_for_test(issue, settings, request_fun)
  end

  test "refreshes a Symphony-owned PR body and preserves a human-edited body" do
    settings = tracker_settings(%{"repositories" => [%{"repository" => "octo/app", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["true"]}]})
    issue = %SymphonyElixir.Tracker.Issue{id: "octo/app#7", branch_name: "symphony/octo-app-7", native_ref: %{repository: "octo/app"}}
    body = "<!-- symphony:delivery:start -->\n\nFixes octo/app#7\n\n## Summary\nUpdated it.\n<!-- symphony:delivery:end -->"
    attrs = %{branch: issue.branch_name, base: "main", sha: "sha-seven", body: body}

    for {existing_body, should_update?} <- [{"<!-- symphony:delivery:start -->\n\nOld report\n<!-- symphony:delivery:end -->", true}, {"Human-edited PR description", false}] do
      calls = Agent.start_link(fn -> [] end) |> elem(1)

      request_fun = fn query, variables, _settings ->
        Agent.update(calls, &[{query, variables} | &1])

        if query =~ "pullRequests" do
          pr = pipeline_pr(issue, existing_body)
          {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => [pr]}}}}}}
        else
          assert should_update?
          assert query =~ "updatePullRequest"
          assert variables["body"] == body
          {:ok, %{status: 200, body: %{"data" => %{"updatePullRequest" => %{"pullRequest" => pipeline_pr(issue, body)}}}}}
        end
      end

      assert {:ok, result} = Client.upsert_pull_request_for_test(issue, attrs, settings, request_fun)

      assert result.body == if(should_update?, do: body, else: existing_body)
      assert length(Agent.get(calls, & &1)) == if(should_update?, do: 2, else: 1)
    end
  end

  test "fetches Ready native issues from the configured Project and qualifies identity by repository" do
    response =
      project_response([
        issue_item("octo/app", 7, "Ready"),
        unsupported_item(),
        draft_item()
      ])

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["Ready", "Building"], tracker_settings(), fn
               query, variables, settings ->
                 assert query =~ "projectV2(number: $number)"
                 assert variables == %{"owner" => "acme", "number" => 12, "after" => nil}
                 assert settings.token == "test-token"
                 {:ok, %{status: 200, body: response}}
             end)

    assert issue.id == "octo/app#7"
    assert issue.identifier == "octo/app#7"
    assert issue.state == "Ready"
    assert issue.branch_name == "symphony/octo-app-7"
    assert issue.dispatchable
    assert issue.requeueable
    assert issue.labels == ["bug"]
  end

  test "Project readiness rejects a missing Status field without writing to GitHub" do
    response = project_response([issue_item("octo/app", 7, "Ready")])
    response = update_in(response, ["data", "organization", "projectV2", "fields", "nodes"], fn _ -> [] end)
    owner = self()

    assert {:error, {:github_projects_configuration_error, message}} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn query, _variables, _settings ->
               send(owner, {:projects_readiness_query, query})
               {:ok, %{status: 200, body: response}}
             end)

    assert message =~ "Project status field \"Status\" was not found"
    assert_received {:projects_readiness_query, query}
    assert query =~ "query SymphonyProject"
    refute query =~ "mutation"
    refute_received {:projects_readiness_query, _query}
  end

  test "Project readiness reports each missing canonical option without writing to GitHub" do
    canonical_options = ["Backlog", "Ready", "Building", "QA", "Review", "Human Review", "Blocked", "Done", "Dropped"]
    owner = self()

    for missing_option <- canonical_options do
      response =
        project_response([issue_item("octo/app", 7, "Ready")])
        |> update_in(
          ["data", "organization", "projectV2", "fields", "nodes", Access.at(0), "options"],
          &Enum.reject(&1, fn option -> option["name"] == missing_option end)
        )

      assert {:error, {:github_projects_configuration_error, message}} =
               Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn query, _variables, _settings ->
                 send(owner, {:projects_readiness_query, query})
                 {:ok, %{status: 200, body: response}}
               end)

      assert message == "Project status field \"Status\" is missing canonical options: #{missing_option}."
      assert_received {:projects_readiness_query, query}
      assert query =~ "query SymphonyProject"
      refute query =~ "mutation"
      refute_received {:projects_readiness_query, _query}
    end
  end

  test "incomplete GitHub Project responses fail readiness without returning issues or writing" do
    response = %{"errors" => [%{"message" => "GitHub returned an incomplete Project response."}]}
    owner = self()

    assert {:error, {:github_projects_api_error, message}} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn query, _variables, _settings ->
               send(owner, {:projects_readiness_query, query})
               {:ok, %{status: 200, body: response}}
             end)

    assert message == "GitHub returned an incomplete Project response."
    assert_received {:projects_readiness_query, query}
    assert query =~ "query SymphonyProject"
    refute query =~ "mutation"
    refute_received {:projects_readiness_query, _query}
  end

  test "pipeline Projects polling returns QA, Review, and Human Review items as dispatchable" do
    statuses = %{
      "backlog" => "Backlog",
      "ready" => "Ready",
      "building" => "Building",
      "qa" => "QA",
      "review" => "Review",
      "human_review" => "Human Review",
      "blocked" => "Blocked",
      "dropped" => "Dropped",
      "done" => "Done"
    }

    settings =
      tracker_settings(%{
        "repositories" => [
          %{"repository" => "octo/app", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["mix test"]}
        ]
      })
      |> Map.merge(%{active_states: ["Ready", "Building", "QA", "Review", "Human Review"], terminal_states: ["closed", "Dropped"]})

    response =
      project_response([
        issue_item("octo/app", 1, "Ready"),
        issue_item("octo/app", 2, "QA"),
        issue_item("octo/app", 3, "Human Review"),
        issue_item("octo/app", 4, "Dropped")
      ])

    response =
      update_in(response, ["data", "organization", "projectV2", "fields", "nodes", Access.at(0), "options"], fn _ ->
        Enum.map(statuses, fn {_key, name} -> %{"id" => "option-#{name}", "name" => name} end)
      end)

    assert {:ok, issues} =
             Client.fetch_issues_by_states_for_test(Map.values(statuses) -- ["Blocked", "Dropped", "Done"], settings, fn
               _query, _variables, _settings -> {:ok, %{status: 200, body: response}}
             end)

    assert Enum.map(issues, & &1.state) == ["Ready", "QA", "Human Review"]
    assert Enum.all?(issues, & &1.dispatchable)
  end

  test "accepts an organization Project when the user lookup returns not found" do
    response =
      project_response([issue_item("octo/app", 7, "Ready")])
      |> update_in(["data"], &Map.put(&1, "user", nil))
      |> Map.put("errors", [
        %{
          "type" => "NOT_FOUND",
          "path" => ["user"],
          "message" => "Could not resolve to a User with the login of 'acme'."
        }
      ])

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn
               _query, _variables, _settings -> {:ok, %{status: 200, body: response}}
             end)

    assert issue.id == "octo/app#7"
  end

  test "ID refreshes match the repository-qualified issue identity" do
    settings =
      tracker_settings(%{
        "repositories" => [
          %{"repository" => "octo/app", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["true"]},
          %{"repository" => "octo/docs", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["true"]}
        ]
      })

    assert {:ok, [issue]} =
             Client.fetch_issues_by_ids_for_test(["octo/docs#7"], settings, fn _query, _variables, _settings ->
               {:ok,
                %{
                  status: 200,
                  body: project_response([issue_item("octo/app", 7, "Ready"), issue_item("octo/docs", 7, "Building")])
                }}
             end)

    assert issue.id == "octo/docs#7"
    assert issue.state == "Building"
    refute issue.requeueable
  end

  test "follows Project item pagination" do
    first_page = project_response([issue_item("octo/app", 7, "Ready")], true)
    second_page = project_response([issue_item("octo/app", 8, "Ready")])
    calls = Agent.start_link(fn -> 0 end) |> elem(1)

    assert {:ok, issues} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn
               _query, variables, _settings ->
                 page = Agent.get_and_update(calls, &{&1, &1 + 1})
                 if page == 0, do: assert(variables["after"] == nil), else: assert(variables["after"] == "cursor-1")
                 body = if page == 0, do: first_page, else: second_page
                 {:ok, %{status: 200, body: body}}
             end)

    assert Enum.map(issues, & &1.id) == ["octo/app#7", "octo/app#8"]
  end

  test "status mutations use discovered field options and Blocked includes an issue comment" do
    settings = tracker_settings()
    issue = issue_item("octo/app", 7, "Ready")

    {:ok, [normalized]} =
      Client.fetch_issues_by_states_for_test(["Ready"], settings, fn _query, _variables, _settings ->
        {:ok, %{status: 200, body: project_response([issue])}}
      end)

    calls = Agent.start_link(fn -> [] end) |> elem(1)

    assert :ok =
             Client.update_issue_status_for_test(normalized, "Blocked", "Needs a person", settings, fn
               query, variables, _settings ->
                 Agent.update(calls, &[{query, variables} | &1])
                 {:ok, %{status: 200, body: %{"data" => %{"updated" => %{"id" => "ok"}}}}}
             end)

    [{comment_query, comment_vars}, {status_query, status_vars}] = Agent.get(calls, & &1)
    assert comment_query =~ "addComment"

    assert comment_vars == %{
             "subjectId" => "I_issue_7",
             "body" => "Symphony moved this Project item to Blocked: Needs a person"
           }

    assert status_query =~ "updateProjectV2ItemFieldValue"
    assert status_vars["fieldId"] == "PVTSSF_status"
    assert status_vars["itemId"] == "PVTI_7"
    assert status_vars["optionId"] == "option-blocked"
  end

  test "Ready is claimed as Building through the configured status option" do
    settings = tracker_settings()

    {:ok, [issue]} =
      Client.fetch_issues_by_states_for_test(["Ready"], settings, fn _query, _variables, _settings ->
        {:ok, %{status: 200, body: project_response([issue_item("octo/app", 7, "Ready")])}}
      end)

    assert :ok =
             Client.update_issue_status_for_test(issue, "Building", "", settings, fn
               query, variables, _settings ->
                 assert query =~ "updateProjectV2ItemFieldValue"
                 assert variables["fieldId"] == "PVTSSF_status"
                 assert variables["optionId"] == "option-building"
                 {:ok, %{status: 200, body: %{"data" => %{"updated" => true}}}}
             end)
  end

  test "completion changes a current Building item to Done but preserves a changed status" do
    settings = tracker_settings()

    {:ok, [stale_issue]} =
      Client.fetch_issues_by_states_for_test(["Ready"], settings, fn _query, _variables, _settings ->
        {:ok, %{status: 200, body: project_response([issue_item("octo/app", 7, "Ready")])}}
      end)

    for {current_status, should_complete?} <- [{"Building", true}, {"Blocked", false}] do
      calls = Agent.start_link(fn -> [] end) |> elem(1)

      assert :ok =
               Client.complete_issue_for_test(stale_issue, settings, fn query, variables, _settings ->
                 if query =~ "updateProjectV2ItemFieldValue" do
                   assert should_complete?
                   assert variables["optionId"] == "option-done"
                   Agent.update(calls, &[variables | &1])
                   {:ok, %{status: 200, body: %{"data" => %{"updated" => true}}}}
                 else
                   {:ok,
                    %{
                      status: 200,
                      body: project_response([issue_item("octo/app", 7, current_status)])
                    }}
                 end
               end)

      assert Agent.get(calls, & &1) != [] == should_complete?
    end
  end

  test "configured Blocked status is exposed for blocked-state reconciliation" do
    assert {:ok, [issue]} =
             Client.fetch_issues_by_ids_for_test(["octo/app#7"], tracker_settings(), fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: project_response([issue_item("octo/app", 7, "Blocked")])}}
             end)

    assert issue.tracker_blocked
    refute issue.dispatchable
    refute issue.requeueable
  end

  test "maps inaccessible Projects responses to actionable permission errors" do
    assert {:error, {:github_projects_permission_error, message}} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn
               _query, _variables, _settings ->
                 {:ok,
                  %{
                    status: 200,
                    body: %{"errors" => [%{"message" => "Resource not accessible by integration"}]}
                  }}
             end)

    assert message =~ "Project read/write"
    assert message =~ "issue read/write"
    refute message =~ "test-token"
  end

  test "closed linked issues become terminal without writing Project status" do
    calls = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["Ready", "Building"], tracker_settings(), fn
               query, variables, _settings ->
                 Agent.update(calls, &[{query, variables} | &1])
                 {:ok, %{status: 200, body: project_response([issue_item("octo/app", 7, "Ready", "CLOSED")])}}
             end)

    assert issue.state == "closed"
    refute issue.dispatchable
    refute Enum.any?(Agent.get(calls, & &1), fn {query, _} -> query =~ "updateProjectV2ItemFieldValue" or query =~ "addComment" end)
  end

  test "closed linked issues without a Project status are observed without writes" do
    calls = Agent.start_link(fn -> [] end) |> elem(1)

    closed_item =
      "octo/app"
      |> issue_item(7, "Ready", "CLOSED")
      |> put_in(["fieldValues", "nodes"], [])

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["closed"], tracker_settings(), fn
               query, variables, _settings ->
                 Agent.update(calls, &[{query, variables} | &1])
                 {:ok, %{status: 200, body: project_response([closed_item])}}
             end)

    assert issue.state == "closed"
    refute issue.dispatchable
    refute Enum.any?(Agent.get(calls, & &1), fn {query, _} -> query =~ "updateProjectV2ItemFieldValue" or query =~ "addComment" end)
  end

  test "an unconfigured repository is ignored without writing Project status or comments" do
    calls = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, []} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn
               query, variables, _settings ->
                 Agent.update(calls, &[{query, variables} | &1])

                 {:ok, %{status: 200, body: project_response([issue_item("other/repo", 8, "Ready")])}}
             end)

    calls = Agent.get(calls, &Enum.reverse/1)
    refute Enum.any?(calls, fn {query, _} -> query =~ "updateProjectV2ItemFieldValue" or query =~ "addComment" end)
  end

  test "issues with the same number in different repositories have distinct identities" do
    settings =
      tracker_settings(%{
        "repositories" => [
          %{"repository" => "octo/app", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["true"]},
          %{"repository" => "octo/docs", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["true"]}
        ]
      })

    assert {:ok, [app, docs]} =
             Client.fetch_issues_by_states_for_test(["Ready"], settings, fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: project_response([issue_item("octo/app", 7, "Ready"), issue_item("octo/docs", 7, "Ready")])}}
             end)

    assert app.id == "octo/app#7"
    assert docs.id == "octo/docs#7"
    refute app.id == docs.id
    refute Workspace.workspace_key(app) == Workspace.workspace_key(docs)
  end

  test "reads native blockers with repository-qualified identities and ignores title matches" do
    settings =
      tracker_settings(%{
        "repositories" => [
          %{"repository" => "octo/app", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["true"]},
          %{"repository" => "octo/docs", "base_branch" => "main", "prepare_command" => "true", "required_checks" => ["true"]}
        ]
      })

    dependent =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], dependency_connection([blocker("octo/app", 8), blocker("octo/docs", 8)]))

    title_only = put_in(issue_item("octo/app", 9, "Ready"), ["content", "title"], "Blocked by #8")

    assert {:ok, issues} =
             Client.fetch_issues_by_states_for_test(["Ready"], settings, fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: project_response([dependent, title_only, issue_item("octo/app", 8, "Ready")])}}
             end)

    assert Enum.find(issues, &(&1.id == "octo/app#7")).blocked_by == [
             %{id: "octo/app#8", identifier: "octo/app#8", state: "OPEN"},
             %{id: "octo/docs#8", identifier: "octo/docs#8", state: "OPEN"}
           ]

    assert Enum.find(issues, &(&1.id == "octo/app#9")).blocked_by == []
  end

  test "follows blocker pages before returning Project issues" do
    dependent =
      issue_item("octo/app", 7, "Ready")
      |> put_in(
        ["content", "blockedBy"],
        dependency_connection([blocker("octo/app", 8)], true, "blocker-cursor", 2)
      )

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn query, variables, _settings ->
               if query =~ "SymphonyIssueBlockers" do
                 assert variables == %{"issueId" => "I_issue_7", "after" => "blocker-cursor"}

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "data" => %{
                        "node" => %{
                          "blockedBy" => dependency_connection([blocker("octo/docs", 8)], false, nil, 2)
                        }
                      }
                    }
                  }}
               else
                 {:ok, %{status: 200, body: project_response([dependent])}}
               end
             end)

    assert Enum.map(issue.blocked_by, & &1.id) == ["octo/app#8", "octo/docs#8"]
  end

  test "incomplete blocker pages and blocker read errors fail the Project read" do
    incomplete =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true}})

    assert {:error, {:github_projects_api_error, _}} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: project_response([incomplete])}}
             end)

    incomplete_count =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], dependency_connection([], false, nil, 1))

    assert {:error, {:github_projects_api_error, _}} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: project_response([incomplete_count])}}
             end)

    paged =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], dependency_connection([], true, "blocker-cursor", 1))

    assert {:error, {:github_projects_api_error, _}} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn query, _variables, _settings ->
               if query =~ "SymphonyIssueBlockers" do
                 {:error, :tracker_read_failed}
               else
                 {:ok, %{status: 200, body: project_response([paged])}}
               end
             end)
  end

  defp run_merge_gate(options) do
    number = System.unique_integer([:positive])
    issue_id = "octo/app##{number}"
    branch = "symphony/octo-app-#{number}"
    sha = String.duplicate("a", 40)

    issue = %Issue{
      id: issue_id,
      identifier: issue_id,
      branch_name: branch,
      state: "Review",
      native_ref: %{repository: "octo/app", base_branch: "main", project_status: "Review"}
    }

    task = %{
      "issue_id" => issue_id,
      "generation" => 1,
      "phase" => "review",
      "attempts" => %{"review" => 1},
      "branch" => branch,
      "base_branch" => "main",
      "current_sha" => sha,
      "required_checks" => ["make -C elixir all"],
      "host_checks" => [
        %{
          "name" => "make -C elixir all",
          "status" => Map.get(options, :host_check_status, "passed"),
          "evidence" => "exit status 0"
        }
      ]
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "review", 1)
    {:ok, queries} = Agent.start_link(fn -> [] end)

    request_fun = fn query, _variables, _settings ->
      Agent.update(queries, &[query | &1])

      cond do
        query =~ "SymphonyProject(" ->
          {:ok, %{status: 200, body: project_response([issue_item("octo/app", number, "Review")])}}

        query =~ "SymphonyPipelineMergeGate" and Map.get(options, :provider_error, false) ->
          {:error, :timeout}

        query =~ "SymphonyPipelineMergeGate" ->
          current_base_sha = Map.get(options, :current_base_sha, "base-current")
          pr_state = Map.get(options, :pr_state, "OPEN")

          pull_request = %{
            "id" => "PR_#{number}",
            "number" => number,
            "url" => "https://github.com/octo/app/pull/#{number}",
            "state" => pr_state,
            "isDraft" => false,
            "mergedAt" => if(pr_state == "MERGED", do: "2026-10-23T08:00:00Z"),
            "baseRefName" => "main",
            "baseRefOid" => Map.get(options, :pr_base_sha, current_base_sha),
            "headRefName" => branch,
            "headRefOid" => Map.get(options, :pr_head_sha, sha),
            "statusCheckRollup" => Map.get(options, :github_check_rollup, %{"state" => Map.get(options, :github_check_status, "SUCCESS")})
          }

          current_ref = merge_gate_base_ref(current_base_sha)
          body = %{"data" => %{"repository" => %{"ref" => current_ref, "pullRequests" => %{"nodes" => [pull_request]}}}}
          {:ok, %{status: 200, body: body}}

        query =~ "SymphonyPipelineMergePullRequest" ->
          body = %{"data" => %{"mergePullRequest" => %{"pullRequest" => %{"mergedAt" => "2026-10-23T08:00:00Z"}}}}
          {:ok, %{status: 200, body: body}}

        query =~ "SymphonyPipelinePullRequest" ->
          merged_pull_request = %{
            "id" => "PR_#{number}",
            "number" => number,
            "url" => "https://github.com/octo/app/pull/#{number}",
            "state" => "MERGED",
            "isDraft" => false,
            "mergedAt" => "2026-10-23T08:00:00Z",
            "baseRefName" => "main",
            "baseRefOid" => Map.get(options, :current_base_sha, "base-current"),
            "headRefName" => branch,
            "headRefOid" => Map.get(options, :pr_head_sha, sha),
            "reviewDecision" => nil,
            "body" => ""
          }

          body = %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => [merged_pull_request]}}}}
          {:ok, %{status: 200, body: body}}

        true ->
          flunk("unexpected GitHub Projects query: #{query}")
      end
    end

    context = %{issue: issue, lane: :review, generation: 1, attempt: 1, task: task}

    result =
      Client.agent_operation(issue, context, "request_merge", %{},
        tracker_settings: tracker_settings(%{"merge_policy" => "auto"}),
        projects_request: request_fun
      )

    calls = Agent.get(queries, &Enum.reverse/1)
    Agent.stop(queries)
    {result, calls}
  end

  defp merge_gate_base_ref(nil), do: nil
  defp merge_gate_base_ref(oid), do: %{"target" => %{"oid" => oid}}

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "github_projects",
      required_labels: [],
      active_states: ["Ready", "Building", "QA", "Review", "Human Review"],
      terminal_states: ["closed", "Dropped"],
      provider:
        Map.merge(
          %{
            "owner" => "acme",
            "project_number" => 12,
            "repositories" => [
              %{
                "repository" => "octo/app",
                "base_branch" => "main",
                "prepare_command" => "true",
                "required_checks" => ["true"]
              }
            ],
            "token" => "test-token"
          },
          provider_overrides
        )
    }
  end

  defp project_response(items, has_next_page \\ false) do
    %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_kwDOProject",
            "fields" => %{
              "nodes" => [
                %{
                  "__typename" => "ProjectV2SingleSelectField",
                  "id" => "PVTSSF_status",
                  "name" => "Status",
                  "options" => [
                    %{"id" => "option-backlog", "name" => "Backlog"},
                    %{"id" => "option-ready", "name" => "Ready"},
                    %{"id" => "option-building", "name" => "Building"},
                    %{"id" => "option-qa", "name" => "QA"},
                    %{"id" => "option-review", "name" => "Review"},
                    %{"id" => "option-human-review", "name" => "Human Review"},
                    %{"id" => "option-blocked", "name" => "Blocked"},
                    %{"id" => "option-done", "name" => "Done"},
                    %{"id" => "option-dropped", "name" => "Dropped"}
                  ]
                }
              ]
            },
            "items" => %{
              "nodes" => items,
              "pageInfo" => %{
                "hasNextPage" => has_next_page,
                "endCursor" => if(has_next_page, do: "cursor-1", else: nil)
              }
            }
          }
        }
      }
    }
  end

  defp issue_item(repository, number, status) do
    %{
      "id" => "PVTI_#{number}",
      "content" => %{
        "__typename" => "Issue",
        "id" => "I_issue_#{number}",
        "number" => number,
        "title" => "Issue #{number}",
        "body" => "Description",
        "state" => "OPEN",
        "url" => "https://github.com/#{repository}/issues/#{number}",
        "repository" => %{"nameWithOwner" => repository},
        "labels" => %{"nodes" => [%{"name" => "Bug"}]},
        "blockedBy" => dependency_connection([])
      },
      "fieldValues" => %{
        "nodes" => [
          %{
            "__typename" => "ProjectV2ItemFieldSingleSelectValue",
            "name" => status,
            "field" => %{"name" => "Status"}
          }
        ]
      }
    }
  end

  defp dependency_connection(blockers, has_next_page \\ false, end_cursor \\ nil, total_count \\ nil) do
    %{
      "nodes" => blockers,
      "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor},
      "totalCount" => total_count || length(blockers)
    }
  end

  defp blocker(repository, number, state \\ "OPEN") do
    %{
      "number" => number,
      "state" => state,
      "repository" => %{"nameWithOwner" => repository}
    }
  end

  defp pipeline_pr(issue, body) do
    %{
      "id" => "PR_pipeline",
      "number" => 107,
      "url" => "https://github.com/octo/app/pull/107",
      "state" => "OPEN",
      "isDraft" => true,
      "mergedAt" => nil,
      "baseRefName" => "main",
      "headRefName" => issue.branch_name,
      "headRefOid" => "sha-seven",
      "body" => body
    }
  end

  defp issue_item(repository, number, status, issue_state) do
    item = issue_item(repository, number, status)
    put_in(item, ["content", "state"], issue_state)
  end

  defp unsupported_item do
    %{
      "id" => "PVTI_PR",
      "content" => %{"__typename" => "PullRequest"},
      "fieldValues" => %{"nodes" => []}
    }
  end

  defp draft_item do
    %{
      "id" => "PVTI_DRAFT",
      "content" => %{"__typename" => "DraftIssue"},
      "fieldValues" => %{"nodes" => []}
    }
  end

  defp write_projects_workflow! do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      tracker:
        kind: github_projects
        active_states: [Ready, Building, QA, Review, Human Review]
        terminal_states: [closed, Dropped]
        provider:
          owner: acme
          project_number: 12
          repositories:
            - repository: octo/app
              base_branch: main
              prepare_command: "true"
              required_checks: ["true"]
          token: test-token
      ---

      Work on {{ issue.identifier }}.
      """
    )

    assert :ok = WorkflowStore.force_reload()
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

defmodule SymphonyElixir.GitHubProjectsAdapterTest.FakeGitHubProjectsClient do
  def fetch_issues_by_states(states), do: notify({:projects_fetch_states, states}, {:ok, []})
  def fetch_issues_by_ids(ids), do: notify({:projects_fetch_ids, ids}, {:ok, []})
  def claim_issue(issue), do: notify({:projects_claim, issue})
  def complete_issue(issue), do: notify({:projects_complete, issue})
  def block_issue(issue, reason), do: notify({:projects_block, issue, reason})
  def set_pipeline_status(issue, status, reason), do: notify({:projects_pipeline_status, issue, status, reason})
  def validate_pipeline_delivery(issue, branch, sha), do: notify({:projects_delivery, issue, branch, sha})

  def upsert_pull_request(issue, attrs),
    do: notify({:projects_upsert_pull_request, issue, attrs}, {:ok, %{number: attrs.number}})

  def set_pull_request_stage(issue, number, stage),
    do: notify({:projects_pull_request_stage, issue, number, stage}, {:ok, %{number: number}})

  def pull_request(issue), do: notify({:projects_pull_request, issue}, {:ok, %{number: 8}})

  def publish_phase_report(issue, marker, body, phase),
    do: notify({:projects_phase_report, issue, marker, body, phase})

  defp notify(message) do
    send(Application.fetch_env!(:symphony_elixir, :projects_lifecycle_test_owner), message)
    :ok
  end

  defp notify(message, result) do
    send(Application.fetch_env!(:symphony_elixir, :projects_lifecycle_test_owner), message)
    result
  end
end
