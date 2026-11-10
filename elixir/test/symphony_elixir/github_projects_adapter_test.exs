defmodule SymphonyElixir.GitHubProjectsAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{AgentReport, AgentTool, Projects.Adapter, Projects.Client}
  alias SymphonyElixir.GitHubProjectsAdapterTest.FakeGitHubProjectsClient
  alias SymphonyElixir.Pipeline
  alias SymphonyElixir.Pipeline.Store

  test "tracker selects the GitHub Projects adapter" do
    assert {:ok, Adapter} =
             Tracker.adapter_for_kind("github_projects")
  end

  test "remote phase recovery reads every page and ignores other authors" do
    issue = %Issue{id: "octo/app#7", identifier: "octo/app#7", native_ref: %{repository: "octo/app", issue_number: 7}}

    comment = fn author, attempt ->
      %{
        "author" => %{"login" => author},
        "body" =>
          "<!-- symphony:report:start:octo/app#7:3:build:#{attempt} -->\n" <>
            "<!-- symphony:report:json\n{\"outcome\":\"ready\",\"sha\":\"abc\"}\n-->\n<!-- symphony:report:end -->"
      }
    end

    request = fn query, vars, _settings ->
      data =
        if query =~ "SymphonyPipelineViewer" do
          %{"viewer" => %{"login" => "agent"}}
        else
          {nodes, next, cursor} =
            if vars["after"] == nil,
              do: {[comment.("agent", 2), comment.("other", 99)], true, "next"},
              else: {[comment.("agent", 4)], false, nil}

          %{"repository" => %{"issue" => %{"comments" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => next, "endCursor" => cursor}}}}}
        end

      {:ok, %{status: 200, body: %{"data" => data}}}
    end

    assert {:ok, reports} = Client.phase_reports_for_test(issue, tracker_settings(), request)
    assert Enum.sort(Enum.map(reports, & &1["attempt"])) == [2, 4]
    assert Enum.all?(reports, &(&1["generation"] == 3 and &1["report"]["sha"] == "abc"))
  end

  test "remote phase recovery rejects incomplete pages and missing continuation cursors" do
    issue = %Issue{id: "octo/app#7", identifier: "octo/app#7", native_ref: %{repository: "octo/app", issue_number: 7}}

    for connection <- [%{"pageInfo" => %{"hasNextPage" => false}}, %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}}] do
      request = fn _query, _vars, _settings ->
        {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"issue" => %{"comments" => connection}}}}}}
      end

      assert {:error, :incomplete_remote_phase_reports} =
               Client.phase_reports_for_test(issue, tracker_settings(), request)
    end
  end

  test "remote phase recovery rejects a pagination cursor cycle" do
    issue = %Issue{id: "octo/app#7", identifier: "octo/app#7", native_ref: %{repository: "octo/app", issue_number: 7}}

    request = fn _query, vars, _settings ->
      cursor = if vars["after"] == "a", do: "b", else: "a"
      comments = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true, "endCursor" => cursor}}
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}}}
    end

    assert {:error, :incomplete_remote_phase_reports} =
             Client.phase_reports_for_test(issue, tracker_settings(), request)
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

  test "a direct QA claim moves a Ready Project item to QA" do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-project-qa-claim-#{System.unique_integer([:positive])}")
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

    issue = %Issue{
      id: issue_id,
      branch_name: "symphony/octo-app-#{number}",
      state: "Ready",
      native_ref: %{repository: "octo/app", base_branch: "main", project_status: "Ready"}
    }

    task = %{"issue_id" => issue_id, "generation" => 1, "phase" => "qa", "status" => "qa", "direct_qa" => true, "current_sha" => "qa-sha", "attempts" => %{"qa" => 1}}

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "qa", 1)

    {:ok, remote_status} = Agent.start_link(fn -> "Ready" end)

    request_fun = fn query, _variables, _settings ->
      cond do
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
            "headRefOid" => "qa-sha",
            "body" => ""
          }

          {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([pr])}}}}}

        query =~ "updateProjectV2ItemFieldValue" ->
          Agent.update(remote_status, fn _status -> "QA" end)
          {:ok, %{status: 200, body: %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_#{number}"}}}}}}

        true ->
          status = Agent.get(remote_status, & &1)
          {:ok, %{status: 200, body: project_response([issue_item("octo/app", number, status)])}}
      end
    end

    context = %{issue: issue, lane: :qa, generation: 1, attempt: 1, task: task}

    assert :ok = Store.save_task(Map.put(task, "qa_claim_pending", true))

    assert {:error, :github_claim_outcome_uncertain} =
             Client.agent_operation(issue, context, "claim", %{},
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )

    assert Agent.get(remote_status, & &1) == "Ready"
    assert :ok = Store.save_task(task)

    assert {:ok, %{"project_item" => %{"status" => "QA"}}} =
             Client.agent_operation(issue, context, "claim", %{},
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )

    assert Agent.get(remote_status, & &1) == "QA"
    assert {:ok, stored} = Store.get_task(issue_id)
    refute Map.has_key?(stored, "direct_qa")

    Agent.update(remote_status, fn _ -> "Building" end)
    building_issue = %{issue | state: "Building", native_ref: %{repository: "octo/app", project_status: "Building"}}
    building_context = %{context | issue: building_issue}

    assert {:ok, %{"project_item" => %{"status" => "QA"}}} =
             Client.agent_operation(building_issue, building_context, "claim", %{},
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )
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
            assert variables == %{"owner" => "octo", "name" => "app", "branch" => "refs/heads/" <> branch}
            body = %{"data" => %{"repository" => %{"ref" => %{"name" => branch, "target" => %{"oid" => sha}}}}}
            {{:ok, %{status: 200, body: body}}, data}

          query =~ "SymphonyPipelinePullRequest" ->
            assert variables == %{"owner" => "octo", "name" => "app", "branch" => branch, "base" => "main"}

            existing_body = """
            Human-authored note before the delivery block.

            <!-- symphony:delivery:start -->

            Old report block.
            <!-- symphony:delivery:end -->

            Human-authored note after the delivery block.
            """

            existing_pr =
              pipeline_pr(issue, existing_body)
              |> Map.merge(%{"number" => 107, "id" => "PR_#{number}", "headRefOid" => sha})

            body = %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([existing_pr])}}}
            {{:ok, %{status: 200, body: body}}, data}

          query =~ "SymphonyUpdatePipelinePullRequestBody" ->
            assert variables["pullRequestId"] == "PR_#{number}"
            assert variables["body"] =~ "Human-authored note before the delivery block."
            assert variables["body"] =~ "Human-authored note after the delivery block."
            assert variables["body"] =~ "Fixes ##{number}"
            refute variables["body"] =~ "Old report block."

            pr =
              pipeline_pr(issue, variables["body"])
              |> Map.merge(%{"number" => 107, "id" => "PR_#{number}", "headRefOid" => sha})

            body = %{"data" => %{"updatePullRequest" => %{"pullRequest" => pr}}}
            {{:ok, %{status: 200, body: body}}, data}

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

    # Tipo de Cambio

    - [x] Refactor

    # Descripción

    Reduce consultas repetidas.

    # Plan de Verificación

    - [x] Pruebas de regresión.
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
    assert evidence["pull_request"]["id"] == "PR_#{number}"
    assert evidence["pull_request"]["number"] == 107
    assert evidence["pull_request"]["head_sha"] == sha
    assert evidence["pull_request"]["base"] == "main"
    assert evidence["pull_request"]["draft"]
  end

  test "Finalize resumes from Ready and verifies the merged PR before moving to Done" do
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
      state: "Ready",
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

    {:ok, remote} = Agent.start_link(fn -> %{status: "Ready", issue_state: "OPEN", events: []} end)

    request_fun = fn query, _variables, _settings ->
      Agent.get_and_update(remote, fn data ->
        cond do
          query =~ "SymphonyProject(" ->
            issue_item = issue_item("octo/app", number, data.status, data.issue_state)
            {{:ok, %{status: 200, body: project_response([issue_item])}}, data}

          query =~ "SymphonyPipelinePullRequest" ->
            events = [:pull_request_read | data.events]
            body = %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([merged_pr])}}}
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

  for initial_status <- ["Ready", "Human Review"] do
    test "the diagnostic lane can block an invalid dependency from #{initial_status}" do
      initial_status = unquote(initial_status)
      previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
      root = Path.join(System.tmp_dir!(), "symphony-project-diagnostic-finalize-#{System.unique_integer([:positive])}")
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

      issue = %Issue{
        id: issue_id,
        identifier: issue_id,
        url: "https://github.com/octo/app/issues/#{number}",
        state: initial_status,
        native_ref: %{repository: "octo/app", base_branch: "main", issue_node_id: "I_issue_#{number}"}
      }

      task = %{"issue_id" => issue_id, "generation" => 1, "phase" => "finalize", "attempts" => %{"finalize" => 1}}
      assert :ok = Store.save_task(task)
      assert :ok = Store.begin_phase(issue_id, 1, "finalize", 1)
      {:ok, remote} = Agent.start_link(fn -> %{status: initial_status} end)

      request_fun = fn query, _variables, _settings ->
        Agent.get_and_update(remote, fn data ->
          cond do
            query =~ "SymphonyProject" ->
              {{:ok, %{status: 200, body: project_response([issue_item("octo/app", number, data.status)])}}, data}

            query =~ "SymphonyPipelineReportComments" ->
              comments = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
              body = %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}
              {{:ok, %{status: 200, body: body}}, data}

            query =~ "SymphonyAddIssueComment" ->
              comment = %{"id" => "IC_diagnostic", "url" => "https://github.com/octo/app/issues/#{number}#issuecomment-1"}
              body = %{"data" => %{"addComment" => %{"commentEdge" => %{"node" => comment}}}}
              {{:ok, %{status: 200, body: body}}, data}

            query =~ "SymphonySetProjectStatus" ->
              body = %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_#{number}"}}}}
              {{:ok, %{status: 200, body: body}}, %{data | status: "Blocked"}}

            true ->
              flunk("unexpected GitHub Projects query: #{query}")
          end
        end)
      end

      reason = "GitHub could not read complete blocker data. Correct the relationship, then move the Project item to Ready."
      report = %{"outcome" => "blocked", "summary" => reason, "reason" => reason, "next_step" => "Correct the relationship, then move the Project item to Ready."}
      markdown = "## Diagnostic report\n\n#{reason}\n\n<!-- symphony:report:json\n#{Jason.encode!(report, pretty: true)}\n-->"
      context = %{issue: issue, lane: :diagnostic, lease_phase: :finalize, generation: 1, attempt: 1, task: task}

      assert {:ok, result} =
               Client.agent_operation(
                 issue,
                 context,
                 "handoff",
                 %{"outcome" => "blocked", "report" => report, "body" => markdown},
                 tracker_settings: tracker_settings(),
                 projects_request: request_fun
               )

      assert result["project_item"]["status"] == "Blocked"
      assert result["comment"]["id"] == "IC_diagnostic"
      assert Agent.get(remote, & &1.status) == "Blocked"
    end
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

    {missing_review, queries} = run_merge_gate(%{review_report: :missing})
    assert {:error, :review_evidence_unavailable} = missing_review
    refute Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))

    {stale_base, queries} = run_merge_gate(%{base_not_ancestor: true})
    assert {:error, :pull_request_base_not_in_head} = stale_base
    assert Enum.any?(queries, &(&1 =~ "SymphonySetProjectStatus"))
    refute Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))

    {missing_stale_review, queries} = run_merge_gate(%{pr_base_sha: "stale-base", review_report: :missing})
    assert {:error, :review_evidence_unavailable} = missing_stale_review
    refute Enum.any?(queries, &(&1 =~ "SymphonySetProjectStatus"))

    {human_changed, queries} = run_merge_gate(%{base_not_ancestor: true, human_decision_changed: true})
    assert {:error, :github_human_decision_changed} = human_changed
    refute Enum.any?(queries, &(&1 =~ "SymphonySetProjectStatus"))

    {without_github_checks, queries} = run_merge_gate(%{github_check_rollup: nil})
    assert {:ok, %{"outcome" => "merged", "pull_request" => %{"merged" => true}}} = without_github_checks
    assert Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))

    {already_merged, queries} = run_merge_gate(%{pr_state: "MERGED"})
    assert {:ok, %{"outcome" => "merged", "pull_request" => %{"merged" => true}}} = already_merged
    refute Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))

    for github_check_status <- ["PENDING", "FAILURE"] do
      {stale_base, queries} =
        run_merge_gate(%{base_changed: true, requeue_github_check_status: github_check_status})

      assert {:error, :pull_request_base_sha_mismatch} = stale_base
      assert Enum.any?(queries, &(&1 =~ "SymphonySetProjectStatus"))
      refute Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))
    end

    {reconciled_merge, queries} = run_merge_gate(%{merge_response_lost: true})
    assert {:ok, %{"outcome" => "merged", "pull_request" => %{"merged" => true}}} = reconciled_merge
    assert Enum.count(queries, &(&1 =~ "SymphonyPipelineMergePullRequest")) == 1

    {unconfirmed_merge, queries} = run_merge_gate(%{merge_response_lost: true, merge_stays_open: true})
    assert {:error, {:github_projects_api_error, _}} = unconfirmed_merge
    assert Enum.count(queries, &(&1 =~ "SymphonyPipelineMergePullRequest")) == 1

    for {scenario, expected_error} <- [
          {%{host_check_status: "failed"}, :host_checks_not_verified},
          {%{human_decision_changed: true}, :github_human_decision_changed},
          {%{issue_closed: true}, :github_issue_closed},
          {%{base_not_ancestor: true}, :pull_request_base_not_in_head},
          {%{base_changed: true}, :pull_request_base_sha_mismatch},
          {%{review_outcome: "changes_requested"}, :review_evidence_unavailable},
          {%{review_sha: String.duplicate("b", 40)}, :review_evidence_unavailable},
          {%{review_author: "someone-else"}, :review_evidence_unavailable},
          {%{prior_findings: [%{"id" => "QA-1"}]}, :review_evidence_unavailable},
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

    assert %{"outcome" => "changes_requested", "findings" => [^finding]} =
             Client.normalize_agent_report_for_test(%{report | "resolutions" => [finding["id"]]}, "review", context)

    assert %{"outcome" => "passed", "findings" => [], "resolutions" => [%{"status" => "resolved", "evidence" => evidence}]} =
             Client.normalize_agent_report_for_test(
               %{report | "resolutions" => [finding["id"] <> " — resolved: the check passed after the fix."]},
               "review",
               context
             )

    assert evidence == "the check passed after the fix."
  end

  test "Review hands off only unresolved findings when its report repeats resolved findings" do
    resolved = %{"id" => "QA-1", "reproduction" => "Old failure", "criterion" => "Works"}
    pending = %{"id" => "QA-2", "reproduction" => "Still fails", "criterion" => "Works"}
    context = %{task: %{"prior_findings" => [resolved, pending]}}
    report = %{"outcome" => "passed", "findings" => [resolved], "resolutions" => ["QA-1: Resuelto; comprobado en QA."]}

    assert %{"outcome" => "changes_requested", "findings" => [^pending]} =
             Client.normalize_agent_report_for_test(report, "review", context)

    assert %{"outcome" => "passed", "findings" => []} =
             Client.normalize_agent_report_for_test(report, "review", %{task: %{"prior_findings" => [resolved]}})
  end

  test "Review routes QA-only findings to QA and mixed findings to Build" do
    qa_finding = %{
      "id" => "QA-EVIDENCE",
      "reproduction" => "Run the configured QA command.",
      "criterion" => "Its saved evidence matches the accepted SHA.",
      "resolution_phase" => "qa"
    }

    product_finding = %{
      "id" => "REV-PRODUCT",
      "reproduction" => "Run the affected product path.",
      "criterion" => "Product behavior matches the acceptance criterion.",
      "resolution_phase" => "build"
    }

    context = %{report_locale: :es, task: %{"prior_findings" => []}}

    qa_result = Client.normalize_agent_report_for_test(%{"outcome" => "changes_requested", "findings" => [qa_finding]}, "review", context)
    mixed_result = Client.normalize_agent_report_for_test(%{"outcome" => "changes_requested", "findings" => [qa_finding, product_finding]}, "review", context)

    assert qa_result["findings"] == [qa_finding]
    assert qa_result["next_step"] =~ "Vuelve a QA"
    assert Pipeline.Findings.review_rework_phase(qa_result["findings"]) == "qa"
    assert mixed_result["findings"] == [qa_finding, product_finding]
    assert mixed_result["next_step"] =~ "Build"
    assert Pipeline.Findings.review_rework_phase(mixed_result["findings"]) == "build"
  end

  test "an unavailable Review check blocks with the command and a recovery action" do
    verification = %{
      "command" => "mise exec -- mix test",
      "status" => "unavailable",
      "evidence" => "The configured command is unavailable on the task host.",
      "sha" => String.duplicate("a", 40),
      "base_sha" => String.duplicate("b", 40),
      "finding_id" => "QA-VERIFICATION"
    }

    result =
      Client.normalize_agent_report_for_test(
        %{"outcome" => "passed", "findings" => [], "resolutions" => []},
        "review",
        %{report_locale: :es, task: %{"prior_findings" => []}, review_verification: verification}
      )

    assert result["outcome"] == "blocked"
    assert result["reason"] =~ "mise exec -- mix test"
    assert result["reason"] =~ "No está disponible"
    assert result["next_step"] =~ "Repara o habilita"
    assert result["findings"] == []
  end

  test "a normalized report visibly identifies the authoritative outcome and pending findings" do
    submitted = %{"outcome" => "passed", "findings" => []}
    finding = %{"id" => "QA-2", "reproduction" => "Still fails", "criterion" => "Works"}
    normalized = %{"outcome" => "changes_requested", "findings" => [finding]}
    body = "Review passed.\n\n<!-- symphony:report:json\n#{Jason.encode!(submitted)}\n-->"

    assert {:ok, published} = AgentReport.normalize_body(body, normalized, submitted)
    visible = published |> String.split("<!-- symphony:report:json") |> hd()
    assert visible =~ "changes_requested"
    assert visible =~ "QA-2"
    assert {:ok, ^normalized} = AgentReport.decode_comment(published)
  end

  test "automatic Review does not overwrite a human move to Human Review" do
    previous = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-human-review-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    issue = %Issue{
      id: "octo/app#90",
      identifier: "octo/app#90",
      branch_name: "symphony/octo-app-90",
      state: "Review",
      native_ref: %{repository: "octo/app", project_status: "Review"}
    }

    sha = String.duplicate("a", 40)

    task = %{
      "issue_id" => issue.id,
      "generation" => 1,
      "phase" => "review",
      "attempts" => %{"review" => 1},
      "current_sha" => sha,
      "base_sha" => "base-current"
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue.id, 1, "review", 1)

    report = %{
      "outcome" => "passed",
      "summary" => "Reviewed.",
      "sha" => sha,
      "base_sha" => "base-current",
      "qa_verification" => %{
        "status" => "passed",
        "sha" => sha,
        "base_sha" => "base-current",
        "command" => "mix test",
        "evidence" => "Host replay passed.",
        "finding_id" => nil
      },
      "findings" => [],
      "resolutions" => []
    }

    body = "Review passed.\n\n<!-- symphony:report:json\n#{Jason.encode!(report)}\n-->"

    request = fn _query, _variables, _settings ->
      {:ok, %{status: 200, body: project_response([issue_item("octo/app", 90, "Human Review")])}}
    end

    context = %{
      issue: issue,
      lane: :review,
      generation: 1,
      attempt: 1,
      task: task,
      review_verification: report["qa_verification"]
    }

    assert {:error, :github_human_decision_changed} =
             Client.agent_operation(issue, context, "handoff", %{"report" => report, "body" => body},
               tracker_settings: tracker_settings(%{"merge_policy" => "auto"}),
               projects_request: request
             )

    closed_request = fn _query, _variables, _settings ->
      {:ok, %{status: 200, body: project_response([issue_item("octo/app", 90, "Review", "CLOSED")])}}
    end

    assert {:error, :github_issue_closed} =
             Client.agent_operation(issue, context, "handoff", %{"report" => report, "body" => body},
               tracker_settings: tracker_settings(%{"merge_policy" => "auto"}),
               projects_request: closed_request
             )
  end

  test "automatic Review requeues to Build when the base advances before handoff" do
    {result, status, report_body, task, queries} = run_review_handoff("Review", "base-new")

    assert {:ok, %{"outcome" => "passed", "project_item" => %{"status" => "Ready"}, "requeued" => true}} = result
    assert status == "Ready"
    assert {:ok, report} = AgentReport.decode_comment(report_body)
    assert report["base_change"] == %{"reviewed_base_sha" => "base-old", "current_base_sha" => "base-new"}
    assert {:ok, %{"stale_merge_retry" => true}} = Store.get_task(task["issue_id"])
    assert Enum.any?(queries, &(&1 =~ "SymphonySetProjectStatus"))
    assert Enum.any?(queries, &(&1 =~ "SymphonyAddIssueComment"))
    refute Enum.any?(queries, &(&1 =~ "SymphonyMarkPipelinePullRequestReady"))
    refute Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))
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
    base_sha = String.duplicate("c", 40)
    old_sha = String.duplicate("b", 40)
    agent_login = "symphony[bot]"
    workpad = "<!-- symphony:workpad:start -->\n## Codex Workpad\n\n### QA\n- Check passed on #{sha}.\n<!-- symphony:workpad:end -->"

    qa_report = %{
      "outcome" => "passed",
      "summary" => "Every acceptance criterion is covered by passing evidence.",
      "sha" => sha,
      "base_sha" => base_sha,
      "criteria" => [
        %{
          "criterion" => "The implementation passes its required checks.",
          "status" => "passed",
          "procedure" => "Run the configured host check on the accepted SHA.",
          "evidence" => ["host:make -C elixir all"]
        }
      ],
      "files" => [],
      "changes" => [],
      "verification_command" => "make -C elixir all",
      "checks" => [],
      "host_checks" => [
        %{
          "name" => "make -C elixir all",
          "status" => "passed",
          "evidence" => "Host exit status 0 on #{sha}.",
          "source" => "host"
        }
      ],
      "gaps" => [],
      "findings" => [],
      "next_step" => "Continue to Review.",
      "reason" => nil
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
      description: "## Acceptance Criteria\n- The implementation passes its required checks.",
      url: "https://github.com/octo/app/issues/#{number}",
      native_ref: %{repository: "octo/app", issue_node_id: "I_issue_#{number}"}
    }

    task = %{
      "issue_id" => issue_id,
      "generation" => 1,
      "phase" => "review",
      "attempts" => %{"review" => 1},
      "current_sha" => sha,
      "base_sha" => base_sha,
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
      review_verification: %{
        "status" => "passed",
        "command" => "make -C elixir all",
        "sha" => sha,
        "base_sha" => base_sha,
        "evidence" => "Host replay passed on #{sha}.",
        "finding_id" => nil
      },
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
    assert evidence["report_context"]["review_verification"] == review_context.review_verification
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

    omitted_criteria_report =
      Map.put(qa_report, "criteria", [])
      |> Jason.encode!(pretty: true)
      |> then(&"<!-- symphony:report:json\n#{&1}\n-->")

    for report_body <- [
          "not a JSON report",
          "<!-- symphony:report:json\nnot JSON\n-->",
          "<!-- symphony:report:json\n{}\n-->\n<!-- symphony:report:json\n{}\n-->",
          omitted_criteria_report
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

  test "Review requires a current QA report, an allowed command, and matching head and base SHAs" do
    sha = String.duplicate("a", 40)
    base_sha = String.duplicate("b", 40)
    command = "mix test"
    report = review_qa_report(sha, base_sha, command)
    context = %{lane: :review, task: %{"current_sha" => sha, "base_sha" => base_sha, "required_checks" => [command]}}
    phase_report = fn value -> %{"body" => "## QA report\n\n<!-- symphony:report:json\n#{Jason.encode!(value)}\n-->"} end

    assert :ok = Client.validate_review_qa_report_for_test(context, %{"qa" => [phase_report.(report)]}, "Run tests.")
    assert {:error, :qa_evidence_unavailable} = Client.validate_review_qa_report_for_test(context, %{}, "Run tests.")

    stale_head = Map.put(report, "sha", String.duplicate("c", 40))
    stale_base = Map.put(report, "base_sha", String.duplicate("d", 40))

    unapproved_command =
      report
      |> Map.put("verification_command", "make test")
      |> Map.put("checks", [
        %{
          "id" => "agent-test",
          "layer" => "unit",
          "command" => "make test",
          "status" => "passed",
          "result" => "Tests passed.",
          "evidence" => "Agent test output.",
          "required" => true,
          "reason" => nil
        }
      ])

    for invalid <- [stale_head, stale_base, unapproved_command] do
      assert {:error, :qa_evidence_unavailable} =
               Client.validate_review_qa_report_for_test(context, %{"qa" => [phase_report.(invalid)]}, "Run tests.")
    end

    current_check = Map.put(hd(report["host_checks"]), "sha", sha)

    stale_second_check = %{
      "name" => "mix format --check-formatted",
      "status" => "passed",
      "evidence" => "Host exit status 0.",
      "source" => "host",
      "sha" => String.duplicate("c", 40)
    }

    stale_other_check =
      report
      |> Map.put("host_checks", [current_check, stale_second_check])
      |> Map.put("checks", report["checks"])

    stale_context = %{context | task: Map.put(context.task, "required_checks", [command, stale_second_check["name"]])}

    assert {:error, :qa_evidence_unavailable} =
             Client.validate_review_qa_report_for_test(stale_context, %{"qa" => [phase_report.(stale_other_check)]}, "Run tests.")
  end

  test "automatic merge rejects stale required check evidence not repeated by Review" do
    required = ["make -C elixir all", "mix format --check-formatted"]
    {result, queries} = run_merge_gate(%{required_checks: required, host_check_sha: "previous-head"})

    assert result == {:error, :host_checks_not_verified}
    refute Enum.any?(queries, &(&1 =~ "SymphonyPipelineMergePullRequest"))
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
             "summary" => "Symphony no pudo ejecutar todas las comprobaciones requeridas.",
             "reason" => "La comprobación requerida `mix test` no está disponible en el host de tareas.",
             "next_step" => recovery
           } = Client.normalize_agent_report_for_test(%{"outcome" => "passed"}, "qa", unavailable)

    assert recovery =~ "mix test"
    assert recovery =~ "vuelve a ejecutar QA"

    assert %{
             "outcome" => "changes_requested",
             "summary" => "QA encontró hallazgos que requieren corrección.",
             "next_step" => "Corrige los hallazgos y vuelve a entregar el trabajo en Build."
           } = Client.normalize_agent_report_for_test(%{"outcome" => "passed", "findings" => [finding]}, "qa", passed)
  end

  test "QA-labeled test changes update the PR SHA and return product findings to Build" do
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
    reported_sha = String.duplicate("b", 40)

    issue = %Issue{
      id: issue_id,
      identifier: issue_id,
      url: "https://github.com/octo/app/issues/#{number}",
      branch_name: "symphony/octo-app-#{number}",
      state: "Ready",
      dispatchable: true,
      labels: ["qa"],
      native_ref: %{repository: "octo/app", base_branch: "main", project_status: "Ready", issue_node_id: "I_issue_#{number}"}
    }

    task = %{
      "issue_id" => issue_id,
      "generation" => 1,
      "phase" => "qa",
      "status" => "qa",
      "direct_qa" => true,
      "attempts" => %{"qa" => 1},
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "current_sha" => sha,
      "base_sha" => "base-current",
      "pr_number" => number,
      "required_checks" => ["mix test"]
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "qa", 1)

    {:ok, remote} = Agent.start_link(fn -> %{status: "Ready", report_body: nil, draft: false, pr_sha: sha} end)

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
              "isDraft" => data.draft,
              "mergedAt" => nil,
              "baseRefName" => "main",
              "headRefName" => issue.branch_name,
              "headRefOid" => data.pr_sha,
              "body" => ""
            }

            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([pr])}}}}}, data}

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
              "headRefOid" => data.pr_sha
            }

            {{:ok, %{status: 200, body: %{"data" => %{"convertPullRequestToDraft" => %{"pullRequest" => pr}}}}}, %{data | draft: true}}

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
            status = %{"option-qa" => "QA", "option-building" => "Building", "option-blocked" => "Blocked"}[variables["optionId"]]
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
      "sha" => reported_sha,
      "criteria" => [],
      "files" => [%{"path" => "test/qa-regression_test.exs", "change" => "added"}],
      "changes" => ["Added test/qa-regression_test.exs."],
      "verification_command" => "mix test",
      "checks" => [
        %{
          "id" => "failed-unit-test",
          "layer" => "unit",
          "command" => "mix test",
          "status" => "failed",
          "result" => "1 test failed.",
          "evidence" => "stale agent result",
          "required" => true,
          "reason" => nil
        }
      ],
      "gaps" => [],
      "reason" => nil
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
    assert Agent.get(remote, & &1.draft)

    Agent.update(remote, &%{&1 | pr_sha: reported_sha})

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
    assert handoff["evidence"]["pull_request"]["head_sha"] == reported_sha

    assert Agent.get(remote, & &1.status) == "Building"

    assert Agent.get(remote, & &1.draft)

    stored_comment = Agent.get(remote, & &1.report_body)
    assert stored_comment =~ "<!-- symphony:report:start:#{issue_id}:1:qa:1 -->"
    assert stored_comment =~ "## QA report\n\nQA found a defect.\n\n"
    assert {:ok, stored_report} = AgentReport.decode_comment(stored_comment)
    assert stored_report["checks"] == report["checks"]
    assert stored_report["sha"] == reported_sha
    assert stored_report["files"] == report["files"]
    assert stored_report["host_checks"] == Enum.map(context.host_checks, &Map.put(&1, "source", "host"))
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
      description: "## Acceptance Criteria\n- The failing scenario must return a valid result.",
      url: "https://github.com/octo/app/issues/#{number}",
      branch_name: "symphony/octo-app-#{number}",
      state: "Ready",
      native_ref: %{repository: "octo/app", base_branch: "main", project_status: "Ready", issue_node_id: "I_issue_#{number}"}
    }

    task = %{
      "issue_id" => issue_id,
      "generation" => 1,
      "phase" => "qa",
      "status" => "building",
      "attempts" => %{"qa" => 1},
      "branch" => issue.branch_name,
      "base_branch" => "main",
      "current_sha" => sha,
      "base_sha" => "base-current",
      "pr_number" => number,
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

            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([pr])}}}}}, data}

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
      "criteria" => [
        %{
          "criterion" => "The failing scenario must return a valid result.",
          "status" => "failed",
          "procedure" => "Run the focused unit test and inspect the returned value.",
          "evidence" => ["focused-unit-test"]
        }
      ],
      "files" => [],
      "changes" => [],
      "verification_command" => "mix test test/symphony_elixir/example_test.exs",
      "checks" => [
        %{
          "id" => "focused-unit-test",
          "layer" => "unit",
          "command" => "mix test test/symphony_elixir/example_test.exs",
          "status" => "failed",
          "result" => "1 test, 1 failure.",
          "evidence" => "test-output: QA-1",
          "required" => true,
          "reason" => nil
        }
      ],
      "host_checks" => [
        %{"name" => "mix test", "status" => "passed", "evidence" => "exit status 0", "source" => "host"}
      ],
      "gaps" => [],
      "reason" => nil
    }

    markdown = "## QA report\n\nQA found a defect.\n\n<!-- symphony:report:json\n#{Jason.encode!(report, pretty: true)}\n-->"

    omitted_criteria = Map.put(report, "criteria", [])

    omitted_handoff =
      AgentTool.execute(
        "github_workflow",
        %{
          "operation" => "handoff",
          "outcome" => "defects_found",
          "report" => omitted_criteria,
          "body" => "## QA report\n\n<!-- symphony:report:json\n#{Jason.encode!(omitted_criteria, pretty: true)}\n-->"
        },
        agent_context: %{
          issue: issue,
          lane: :qa,
          generation: 1,
          attempt: 1,
          task: task,
          host_checks: [%{"name" => "mix test", "status" => "passed", "evidence" => "exit status 0"}]
        },
        tracker_settings: tracker_settings(),
        projects_request: fn _query, _variables, _settings -> flunk("an omitted acceptance criterion must fail before GitHub writes") end
      )

    refute omitted_handoff["success"]
    assert Jason.decode!(omitted_handoff["output"])["error"]["reason"] == ":invalid_qa_report"

    context = %{
      issue: issue,
      lane: :qa,
      generation: 1,
      attempt: 1,
      task: task,
      host_checks: [%{"name" => "mix test", "status" => "passed", "evidence" => "exit status 0"}],
      tracker_kind: "github_projects"
    }

    stale_report = Map.put(report, "sha", String.duplicate("b", 40))

    stale_handoff =
      AgentTool.execute(
        "github_workflow",
        %{
          "operation" => "handoff",
          "outcome" => "defects_found",
          "report" => stale_report,
          "body" => "## QA report\n\nQA found a defect.\n\n<!-- symphony:report:json\n#{Jason.encode!(stale_report, pretty: true)}\n-->"
        },
        agent_context: context,
        tracker_settings: tracker_settings(),
        projects_request: fn _query, _variables, _settings -> flunk("a SHA mismatch must fail before GitHub writes") end
      )

    refute stale_handoff["success"]
    assert Jason.decode!(stale_handoff["output"])["error"]["reason"] == ":qa_report_sha_mismatch"

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
    assert stored_report["checks"] == report["checks"]
    assert stored_report["host_checks"] == Enum.map(context.host_checks, &Map.put(&1, "source", "host"))

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
    assert workpad["report_context"]["task"]["branch"] == issue.branch_name
    assert workpad["report_context"]["task"]["base_branch"] == "main"
    assert workpad["report_context"]["task"]["pr_number"] == number
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

  test "Review routes findings, rejects stale SHA, and reconciles an uncertain QA handoff" do
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

    {:ok, remote} =
      Agent.start_link(fn ->
        %{status: "Ready", draft: false, comments: [], lose_qa_status_once: true, status_updates: 0}
      end)

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

            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([pr])}}}}}, data}

          query =~ "SymphonyPipelineReportComments" ->
            comments = %{"nodes" => data.comments, "pageInfo" => %{"hasNextPage" => false}}
            {{:ok, %{status: 200, body: %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}}}, data}

          query =~ "SymphonyAddIssueComment" ->
            comment = %{
              "id" => "IC_review_#{length(data.comments) + 1}",
              "url" => "https://github.com/octo/app/issues/#{number}#issuecomment-#{length(data.comments) + 1}",
              "author" => %{"login" => "agent"},
              "body" => variables["body"]
            }

            body = %{"data" => %{"addComment" => %{"commentEdge" => %{"node" => comment}}}}
            {{:ok, %{status: 200, body: body}}, %{data | comments: data.comments ++ [comment]}}

          query =~ "SymphonyPipelineViewer" ->
            {{:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "agent"}}}}}, data}

          query =~ "SymphonyUpdateAgentReport" ->
            comment = Enum.find(data.comments, &(&1["id"] == variables["id"]))
            updated = Map.put(comment, "body", variables["body"])
            comments = Enum.map(data.comments, &if(&1["id"] == variables["id"], do: updated, else: &1))
            body = %{"data" => %{"updateIssueComment" => %{"issueComment" => updated}}}
            {{:ok, %{status: 200, body: body}}, %{data | comments: comments}}

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
            status = %{"option-review" => "Review", "option-building" => "Building", "option-qa" => "QA"}[variables["optionId"]]
            updated = %{data | status: status, status_updates: data.status_updates + 1}

            if status == "QA" and data.lose_qa_status_once do
              {{:error, :response_lost}, %{updated | lose_qa_status_once: false}}
            else
              {{:ok, %{status: 200, body: body}}, updated}
            end

          true ->
            flunk("unexpected GitHub Projects query: #{query}")
        end
      end)
    end

    finding = %{"id" => "REV-1", "reproduction" => "Run the affected path.", "criterion" => "The review criterion passes.", "resolution_phase" => "build"}

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

    task = Map.put(task, "attempts", %{"review" => 2})
    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "review", 2)
    Agent.update(remote, &%{&1 | status: "Review"})
    context = %{context | attempt: 2, task: task}

    qa_finding = %{
      "id" => "QA-EVIDENCE-1",
      "reproduction" => "Run the configured QA command and inspect the saved evidence.",
      "criterion" => "The QA command and evidence match the accepted SHA.",
      "resolution_phase" => "qa"
    }

    qa_report = %{
      "outcome" => "changes_requested",
      "summary" => "Review found a QA evidence defect.",
      "findings" => [qa_finding],
      "resolutions" => [],
      "next_step" => "Return the finding to QA.",
      "sha" => sha,
      "branch" => issue.branch_name,
      "base_branch" => "main"
    }

    stale_report = Map.put(qa_report, "sha", String.duplicate("a", 40))
    stale_body = "## Review report\n\nEvidence is stale.\n\n<!-- symphony:report:json\n#{Jason.encode!(stale_report, pretty: true)}\n-->"

    assert {:error, :review_report_sha_mismatch} =
             Client.agent_operation(
               issue,
               context,
               "handoff",
               %{"outcome" => "changes_requested", "report" => stale_report, "body" => stale_body},
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )

    assert Agent.get(remote, & &1.status) == "Review"
    assert Agent.get(remote, & &1.status_updates) == 2

    qa_body = "## Review report\n\nReview found QA evidence that needs correction.\n\n<!-- symphony:report:json\n#{Jason.encode!(qa_report, pretty: true)}\n-->"
    qa_arguments = %{"outcome" => "changes_requested", "report" => qa_report, "body" => qa_body}

    assert {:error, {:github_projects_api_error, _}} =
             Client.agent_operation(issue, context, "handoff", qa_arguments,
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )

    assert Agent.get(remote, & &1.status) == "QA"
    assert Agent.get(remote, & &1.status_updates) == 3

    assert {:ok, %{"project_item" => %{"status" => "QA"}, "pull_request" => %{"draft" => true}}} =
             Client.agent_operation(issue, context, "handoff", qa_arguments,
               tracker_settings: tracker_settings(),
               projects_request: request_fun
             )

    assert Agent.get(remote, & &1.status) == "QA"
    assert Agent.get(remote, & &1.status_updates) == 3
    assert length(Agent.get(remote, & &1.comments)) == 2
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
          {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([])}}}}}

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
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([])}}}}}
    end

    assert {:error, :github_pull_request_body_required} =
             Client.upsert_pull_request_for_test(
               issue,
               %{branch: issue.branch_name, base: "main"},
               settings,
               request_fun
             )
  end

  test "a failed or ambiguous pull request lookup never starts a parallel PR creation" do
    settings = tracker_settings()
    issue = %SymphonyElixir.Tracker.Issue{id: "octo/app#7", branch_name: "symphony/octo-app-7", native_ref: %{repository: "octo/app"}}
    attrs = %{branch: issue.branch_name, base: "main", sha: "sha-seven", body: "Fixes #7\n\nDescription"}
    truncated_nodes = Enum.map(1..100, &(pipeline_pr(issue, "") |> Map.merge(%{"number" => &1, "state" => "CLOSED"})))

    lookup_results = [
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => %{}}}}}},
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => "incomplete"}}}}}},
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => %{"nodes" => []}}}}}},
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "pullRequests" => %{"nodes" => truncated_nodes, "pageInfo" => %{"hasNextPage" => true}}
             }
           }
         }
       }},
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "repository" => %{
               "pullRequests" => pipeline_pull_request_connection([pipeline_pr(issue, "body") |> Map.put("headRefName", "symphony/wrong-issue")])
             }
           }
         }
       }},
      {:error, :read_failed}
    ]

    for lookup_result <- lookup_results do
      requests = Agent.start_link(fn -> [] end) |> elem(1)

      request_fun = fn query, variables, _settings ->
        Agent.update(requests, &[query | &1])

        cond do
          query =~ "SymphonyPipelinePullRequest" ->
            assert query =~ "pageInfo { hasNextPage }"
            lookup_result

          query =~ "SymphonyPipelineRepository" ->
            {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"id" => "R_octopus"}}}}}

          query =~ "createPullRequest" ->
            pr = pipeline_pr(issue, variables["input"]["body"])
            {:ok, %{status: 200, body: %{"data" => %{"createPullRequest" => %{"pullRequest" => pr}}}}}
        end
      end

      assert {:error, _reason} = Client.upsert_pull_request_for_test(issue, attrs, settings, request_fun)
      assert Agent.get(requests, &length/1) == 1
      refute Enum.any?(Agent.get(requests, & &1), &(&1 =~ "createPullRequest"))
    end
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

      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([merged_pr])}}}}}
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
          {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([pr])}}}}}
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

  test "an existing PR with a stale head SHA is rejected before updating its body" do
    settings = tracker_settings()
    issue = %SymphonyElixir.Tracker.Issue{id: "octo/app#7", branch_name: "symphony/octo-app-7", native_ref: %{repository: "octo/app"}}
    body = "<!-- symphony:delivery:start -->\n\nNew report\n<!-- symphony:delivery:end -->"
    attrs = %{branch: issue.branch_name, base: "main", sha: "sha-seven", body: body}
    calls = Agent.start_link(fn -> [] end) |> elem(1)

    request_fun = fn query, variables, _settings ->
      Agent.update(calls, &[{query, variables} | &1])
      assert query =~ "SymphonyPipelinePullRequest"
      assert variables == %{"owner" => "octo", "name" => "app", "branch" => issue.branch_name, "base" => "main"}

      pr = pipeline_pr(issue, "<!-- symphony:delivery:start -->\n\nOld report\n<!-- symphony:delivery:end -->")
      pr = Map.put(pr, "headRefOid", "stale-sha")
      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([pr])}}}}}
    end

    assert {:error, :pull_request_head_sha_mismatch} =
             Client.upsert_pull_request_for_test(issue, attrs, settings, request_fun)

    assert Agent.get(calls, &length/1) == 1
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

  test "Ready issues use the Status field update time as their Ready timestamp" do
    ready_since = "2026-10-30T09:15:00Z"

    item =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "createdAt"], "2026-01-01T00:00:00Z")
      |> put_in(["fieldValues", "nodes", Access.at(0), "createdAt"], "2026-10-20T00:00:00Z")
      |> put_in(["fieldValues", "nodes", Access.at(0), "updatedAt"], ready_since)

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn query, _variables, _settings ->
               assert query =~ "updatedAt"
               {:ok, %{status: 200, body: project_response([item])}}
             end)

    assert issue.created_at == ~U[2026-01-01 00:00:00Z]
    assert issue.ready_at == ~U[2026-10-30 09:15:00Z]
  end

  test "Ready issues have no Ready timestamp when the Status update time is unavailable" do
    item =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "createdAt"], "2026-01-01T00:00:00Z")
      |> put_in(["fieldValues", "nodes", Access.at(0), "createdAt"], "2026-10-20T00:00:00Z")

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: project_response([item])}}
             end)

    assert issue.created_at == ~U[2026-01-01 00:00:00Z]
    assert issue.ready_at == nil
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

  test "repository profile preparation is selected by repo and an invalid profile stays isolated" do
    root = Path.join(System.tmp_dir!(), "symphony-project-profiles-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(root)
    write_projects_workflow!(workspace_root)

    mix_source = create_test_repository!(Path.join(root, "mix-source"), "example-org/mix-app")
    node_source = create_test_repository!(Path.join(root, "node-source"), "another-org/node-app")

    profiles = [
      project_repository("example-org/mix-app", mix_source)
      |> Map.put(
        "prepare_command",
        "git clone --quiet '#{mix_source}' . && printf '%s\\n' 'mix-runtime' > runtime.txt && printf '%s\\n' \"$SYMPHONY_REPOSITORY\" > selected-repository.txt"
      ),
      project_repository("another-org/node-app", node_source)
      |> Map.put(
        "prepare_command",
        "git clone --quiet '#{node_source}' . && printf '%s\\n' 'node-runtime' > runtime.txt && printf '%s\\n' \"$SYMPHONY_REPOSITORY\" > selected-repository.txt"
      ),
      %{"repository" => "broken-org/unready-app", "base_branch" => "main", "required_checks" => ["true"]}
    ]

    settings = tracker_settings(%{"repositories" => profiles})

    items = [
      issue_item("example-org/mix-app", 71, "Ready")
      |> put_in(["content", "body"], "issue mentions another-org/node-app"),
      issue_item("another-org/node-app", 72, "Ready"),
      issue_item("broken-org/unready-app", 73, "Ready")
    ]

    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = Client.validate_settings(settings)

    assert {:ok, issues} =
             Client.fetch_issues_by_states_for_test(["Ready"], settings, fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: project_response(items)}}
             end)

    mix_issue = Enum.find(issues, &(&1.id == "example-org/mix-app#71"))
    node_issue = Enum.find(issues, &(&1.id == "another-org/node-app#72"))
    invalid_issue = Enum.find(issues, &(&1.id == "broken-org/unready-app#73"))

    assert invalid_issue.dispatchable
    assert invalid_issue.native_ref.repository_profile_error == :missing_prepare_command
    assert {:error, {:repository_profile_invalid, :missing_prepare_command}} = Workspace.create_for_issue(invalid_issue)

    assert {:ok, mix_workspace} = Workspace.create_for_issue(mix_issue)
    assert File.read!(Path.join(mix_workspace, "runtime.txt")) == "mix-runtime\n"
    assert File.read!(Path.join(mix_workspace, "selected-repository.txt")) == "example-org/mix-app\n"

    assert {:ok, node_workspace} = Workspace.create_for_issue(node_issue)
    assert File.read!(Path.join(node_workspace, "runtime.txt")) == "node-runtime\n"
    assert File.read!(Path.join(node_workspace, "selected-repository.txt")) == "another-org/node-app\n"
  end

  test "same-number issues in different repositories get independent tasks, workspaces, branches, and PRs" do
    root = Path.join(System.tmp_dir!(), "symphony-project-identity-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    previous_database_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    previous_client = Application.fetch_env(:symphony_elixir, :github_projects_client_module)

    File.mkdir_p!(root)
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))
    Application.put_env(:symphony_elixir, :github_projects_client_module, FakeGitHubProjectsClient)
    write_projects_workflow!(workspace_root)

    on_exit(fn ->
      case previous_database_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      case previous_client do
        {:ok, client} -> Application.put_env(:symphony_elixir, :github_projects_client_module, client)
        :error -> Application.delete_env(:symphony_elixir, :github_projects_client_module)
      end

      File.rm_rf!(root)
    end)

    app_source = create_test_repository!(Path.join(root, "octo-app"), "octo/app")
    docs_source = create_test_repository!(Path.join(root, "other-app"), "other/app")

    settings =
      tracker_settings(%{
        "repositories" => [
          project_repository("octo/app", app_source),
          project_repository("other/app", docs_source)
        ]
      })

    app_item = issue_item("octo/app", 7, "Ready") |> Map.put("id", "PVTI_app_7")
    docs_item = issue_item("other/app", 7, "Ready") |> Map.put("id", "PVTI_other_app_7")

    assert {:ok, [app, docs]} =
             Client.fetch_issues_by_states_for_test(["Ready"], settings, fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: project_response([app_item, docs_item])}}
             end)

    assert app.id == "octo/app#7"
    assert docs.id == "other/app#7"
    refute app.id == docs.id
    assert Issue.execution_identity(app) =~ app.native_ref.project_id
    assert Issue.execution_identity(app) =~ app.native_ref.project_item_id
    assert Issue.execution_identity(app) =~ "octo/app#7"
    refute Issue.execution_identity(app) == Issue.execution_identity(docs)
    refute Workspace.workspace_key(app) == Workspace.workspace_key(docs)
    assert Workspace.workspace_key(app) =~ "PVT_kwDOProject"
    assert Workspace.workspace_key(app) =~ "PVTI_app_7"
    assert app.branch_name == "symphony/octo-app-7"
    assert docs.branch_name == "symphony/other-app-7"

    assert {:ok, app_task, "build"} = Pipeline.prepare(app)
    assert {:ok, docs_task, "build"} = Pipeline.prepare(docs)
    assert app_task["execution_identity"] == Issue.execution_identity(app)
    assert docs_task["execution_identity"] == Issue.execution_identity(docs)
    refute app_task["execution_identity"] == docs_task["execution_identity"]
    assert {:ok, ^app_task} = Store.get_task(app.id)
    assert {:ok, ^docs_task} = Store.get_task(docs.id)

    assert {:ok, app_workspace} = Workspace.create_for_issue(app)
    assert {:ok, docs_workspace} = Workspace.create_for_issue(docs)
    assert Path.basename(app_workspace) == Workspace.workspace_key(app)
    assert Path.basename(docs_workspace) == Workspace.workspace_key(docs)
    refute app_workspace == docs_workspace
    assert git!(app_workspace, ["branch", "--show-current"]) == app.branch_name
    assert git!(docs_workspace, ["branch", "--show-current"]) == docs.branch_name
    assert File.read!(Path.join(app_workspace, "repository.txt")) == "octo/app\n"
    assert File.read!(Path.join(docs_workspace, "repository.txt")) == "other/app\n"

    for {issue, owner, repository} <- [{app, "octo", "app"}, {docs, "other", "app"}] do
      assert {:ok, pull_request} =
               Client.pull_request_for_test(issue, settings, fn query, variables, _settings ->
                 assert query =~ "repository(owner: $owner, name: $name)"
                 assert variables["owner"] == owner
                 assert variables["name"] == repository
                 assert variables["branch"] == issue.branch_name
                 connection = pipeline_pull_request_connection([pipeline_pr(issue, "")])
                 {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequests" => connection}}}}}
               end)

      assert pull_request.branch == issue.branch_name
      assert pull_request.url == "https://github.com/#{owner}/#{repository}/pull/107"
    end
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

  test "invalid dependency data stays attached to the affected Project issue" do
    incomplete =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true}})

    incomplete_count =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], dependency_connection([], false, nil, 1))

    unresolved_identity =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], dependency_connection([blocker("octo/app", 0)]))

    ambiguous =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], dependency_connection([blocker("octo/app", 8), blocker("octo/app", 8)]))

    unknown_state =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], dependency_connection([blocker("octo/app", 8, "MERGED")]))

    for item <- [incomplete, incomplete_count, unresolved_identity, ambiguous, unknown_state] do
      assert {:ok, [issue]} =
               Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn _query, _variables, _settings ->
                 {:ok, %{status: 200, body: project_response([item])}}
               end)

      assert issue.id == "octo/app#7"
      assert issue.blocked_by == []
      assert is_binary(issue.dependency_error)
    end
  end

  test "blocker permission errors are diagnosed while transient page read failures retry" do
    paged =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], dependency_connection([blocker("octo/app", 8)], true, "blocker-cursor", 2))

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn query, _variables, _settings ->
               if query =~ "SymphonyIssueBlockers" do
                 {:ok, %{status: 403, body: %{}}}
               else
                 {:ok, %{status: 200, body: project_response([paged])}}
               end
             end)

    assert issue.dependency_error =~ "access"

    assert {:error, {:github_projects_api_error, _}} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn query, _variables, _settings ->
               if query =~ "SymphonyIssueBlockers" do
                 {:error, :tracker_read_failed}
               else
                 {:ok, %{status: 200, body: project_response([paged])}}
               end
             end)
  end

  test "partial dependency responses retain the issue and a corrected relationship can be read again" do
    partial =
      project_response([issue_item("octo/app", 7, "Ready")])
      |> update_in(["data"], &Map.put(&1, "user", nil))
      |> Map.put("errors", [
        %{
          "type" => "NOT_FOUND",
          "path" => ["user"],
          "message" => "Could not resolve to a User with the login of 'acme'."
        },
        %{
          "type" => "FORBIDDEN",
          "path" => ["organization", "projectV2", "items", "nodes", 0, "content", "blockedBy"],
          "message" => "Resource not accessible by integration"
        }
      ])

    assert {:ok, [invalid]} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: partial}}
             end)

    assert invalid.dependency_error =~ "access"

    corrected =
      issue_item("octo/app", 7, "Ready")
      |> put_in(["content", "blockedBy"], dependency_connection([blocker("octo/docs", 8, "CLOSED")]))

    assert {:ok, [recovered]} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn _query, _variables, _settings ->
               {:ok, %{status: 200, body: project_response([corrected])}}
             end)

    assert recovered.dependency_error == nil
    assert recovered.blocked_by == [%{id: "octo/docs#8", identifier: "octo/docs#8", state: "CLOSED"}]
  end

  defp run_merge_gate(options) do
    number = System.unique_integer([:positive])
    issue_id = "octo/app##{number}"
    branch = "symphony/octo-app-#{number}"
    sha = String.duplicate("a", 40)
    required_checks = Map.get(options, :required_checks, ["make -C elixir all"])
    verification_command = List.first(required_checks)

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
      "base_sha" => "base-current",
      "prior_findings" => Map.get(options, :prior_findings, []),
      "required_checks" => required_checks,
      "host_checks" =>
        Enum.map(required_checks, fn command ->
          %{
            "name" => command,
            "status" => Map.get(options, :host_check_status, "passed"),
            "evidence" => "exit status 0",
            "source" => "host",
            "sha" => Map.get(options, :host_check_sha, sha)
          }
        end)
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "review", 1)
    {:ok, queries} = Agent.start_link(fn -> [] end)

    request_fun = fn query, variables, _settings ->
      Agent.update(queries, &[query | &1])

      cond do
        query =~ "SymphonyProject(" ->
          merge_gate_project(options, queries, number)

        query =~ "SymphonyPipelineViewer" ->
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"login" => "agent"}}}}}

        query =~ "SymphonyPipelineReportComments" ->
          merge_gate_comments(options, issue, sha)

        query =~ "SymphonyPipelineMergeGate" ->
          merge_gate_query_with_changes(options, queries, number, branch, sha)

        query =~ "SymphonyPipelineMergePullRequest" or query =~ "SymphonyPipelinePullRequest" ->
          merge_gate_pull_request_response(query, options, queries, number, branch, sha)

        query =~ "SymphonySetProjectStatus" ->
          assert variables["optionId"] == "option-ready"
          {:ok, %{status: 200, body: %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_#{number}"}}}}}}

        true ->
          flunk("unexpected GitHub Projects query: #{query}")
      end
    end

    context = %{
      issue: issue,
      lane: :review,
      generation: 1,
      attempt: 1,
      task: task,
      review_verification: %{
        "command" => verification_command,
        "status" => "passed",
        "evidence" => "Host replay passed.",
        "sha" => sha,
        "base_sha" => task["base_sha"]
      }
    }

    result =
      Client.agent_operation(issue, context, "request_merge", %{},
        tracker_settings: tracker_settings(%{"merge_policy" => "auto"}),
        projects_request: request_fun,
        github_rest: fn "GET", _path, _params, _body, _settings -> merge_gate_comparison(options) end
      )

    calls = Agent.get(queries, &Enum.reverse/1)
    Agent.stop(queries)
    {result, calls}
  end

  defp run_review_handoff(initial_status, pr_base_sha) do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-review-handoff-#{System.unique_integer([:positive])}")
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
    branch = "symphony/octo-app-#{number}"
    sha = String.duplicate("a", 40)
    old_base_sha = "base-old"

    issue = %Issue{
      id: issue_id,
      identifier: issue_id,
      branch_name: branch,
      state: initial_status,
      native_ref: %{repository: "octo/app", base_branch: "main", issue_node_id: "I_issue_#{number}"}
    }

    verification = %{
      "status" => "passed",
      "sha" => sha,
      "base_sha" => old_base_sha,
      "command" => "mix test",
      "evidence" => "Host replay passed."
    }

    task = %{
      "issue_id" => issue_id,
      "generation" => 1,
      "phase" => "review",
      "status" => "review",
      "attempts" => %{"review" => 1},
      "branch" => branch,
      "base_branch" => "main",
      "current_sha" => sha,
      "base_sha" => old_base_sha,
      "required_checks" => ["mix test"],
      "prior_findings" => []
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 1, "review", 1)

    report = %{
      "outcome" => "passed",
      "summary" => "Reviewed the accepted head and base.",
      "sha" => sha,
      "base_sha" => old_base_sha,
      "findings" => [],
      "resolutions" => [],
      "next_step" => "Continue to the merge gate."
    }

    body = "Review passed.\n\n<!-- symphony:report:json\n#{Jason.encode!(report)}\n-->"
    {:ok, remote} = Agent.start_link(fn -> %{status: initial_status, queries: [], report_body: nil} end)

    request = fn query, variables, _settings ->
      Agent.get_and_update(remote, fn state ->
        review_handoff_response(query, variables, state, number, branch, sha, pr_base_sha)
      end)
    end

    context = %{issue: issue, lane: :review, generation: 1, attempt: 1, task: task, review_verification: verification}

    result =
      Client.agent_operation(issue, context, "handoff", %{"report" => report, "body" => body},
        tracker_settings: tracker_settings(%{"merge_policy" => "auto"}),
        projects_request: request
      )

    state = Agent.get(remote, & &1)
    Agent.stop(remote)
    {result, state.status, state.report_body, task, Enum.reverse(state.queries)}
  end

  defp review_handoff_response(query, variables, state, number, branch, sha, pr_base_sha) do
    state = %{state | queries: [query | state.queries]}

    cond do
      query =~ "SymphonyProject" ->
        body = project_response([issue_item("octo/app", number, state.status)])
        {{:ok, %{status: 200, body: body}}, state}

      query =~ "SymphonyPipelinePullRequest" ->
        pull_request = %{
          "id" => "PR_#{number}",
          "number" => number,
          "url" => "https://github.com/octo/app/pull/#{number}",
          "state" => "OPEN",
          "isDraft" => true,
          "mergedAt" => nil,
          "baseRefName" => "main",
          "baseRefOid" => pr_base_sha,
          "headRefName" => branch,
          "headRefOid" => sha,
          "reviewDecision" => nil,
          "body" => ""
        }

        body = %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([pull_request])}}}
        {{:ok, %{status: 200, body: body}}, state}

      query =~ "SymphonyPipelineReportComments" ->
        comments = %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
        body = %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}
        {{:ok, %{status: 200, body: body}}, state}

      query =~ "SymphonyAddIssueComment" ->
        comment = %{"id" => "IC_review_#{number}", "url" => "https://github.com/octo/app/issues/#{number}#issuecomment-1"}
        body = %{"data" => %{"addComment" => %{"commentEdge" => %{"node" => comment}}}}
        {{:ok, %{status: 200, body: body}}, %{state | report_body: variables["body"]}}

      query =~ "SymphonySetProjectStatus" ->
        body = %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_#{number}"}}}}
        {{:ok, %{status: 200, body: body}}, %{state | status: "Ready"}}

      true ->
        flunk("unexpected handoff query: #{query}")
    end
  end

  defp merge_gate_pull_request_response(query, options, queries, number, branch, sha) do
    if String.contains?(query, "SymphonyPipelineMergePullRequest"),
      do: merge_gate_merge_response(options),
      else: merge_gate_pull_request_read_response(options, queries, number, branch, sha)
  end

  defp merge_gate_merge_response(%{merge_response_lost: true}), do: {:error, :response_lost}

  defp merge_gate_merge_response(_options) do
    body = %{"data" => %{"mergePullRequest" => %{"pullRequest" => %{"mergedAt" => "2026-10-23T08:00:00Z"}}}}
    {:ok, %{status: 200, body: body}}
  end

  defp merge_gate_pull_request_read_response(options, queries, number, branch, sha) do
    state = merge_gate_pull_request_state(options, queries)

    merged_pull_request = %{
      "id" => "PR_#{number}",
      "number" => number,
      "url" => "https://github.com/octo/app/pull/#{number}",
      "state" => state,
      "isDraft" => state != "MERGED",
      "mergedAt" => if(state == "MERGED", do: "2026-10-23T08:00:00Z"),
      "baseRefName" => "main",
      "baseRefOid" => Map.get(options, :current_base_sha, "base-current"),
      "headRefName" => branch,
      "headRefOid" => Map.get(options, :pr_head_sha, sha),
      "reviewDecision" => nil,
      "body" => ""
    }

    body = %{"data" => %{"repository" => %{"pullRequests" => pipeline_pull_request_connection([merged_pull_request])}}}
    {:ok, %{status: 200, body: body}}
  end

  defp merge_gate_query_with_changes(options, queries, number, branch, sha) do
    reads = Agent.get(queries, &Enum.count(&1, fn query -> query =~ "SymphonyPipelineMergeGate" end))
    options = if options[:base_changed] == true and reads > 1, do: Map.put(options, :current_base_sha, "new-base"), else: options
    options = if reads > 2 and is_binary(options[:requeue_github_check_status]), do: Map.put(options, :github_check_status, options[:requeue_github_check_status]), else: options
    merge_gate_query(options, number, branch, sha)
  end

  defp merge_gate_pull_request_state(options, queries) do
    merge_attempted? = Agent.get(queries, &Enum.any?(&1, fn query -> query =~ "SymphonyPipelineMergePullRequest" end))

    cond do
      options[:merge_response_lost] == true and merge_attempted? and options[:merge_stays_open] == true -> "OPEN"
      options[:merge_response_lost] == true and merge_attempted? -> "MERGED"
      true -> "MERGED"
    end
  end

  defp merge_gate_comparison(options) do
    base = if options[:base_not_ancestor], do: "different-base", else: Map.get(options, :current_base_sha, "base-current")
    {:ok, %{status: 200, body: %{"merge_base_commit" => %{"sha" => base}}}}
  end

  defp merge_gate_query(%{provider_error: true}, _number, _branch, _sha), do: {:error, :timeout}

  defp merge_gate_query(options, number, branch, sha) do
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
    body = %{"data" => %{"repository" => %{"ref" => current_ref, "pullRequests" => pipeline_pull_request_connection([pull_request])}}}
    {:ok, %{status: 200, body: body}}
  end

  defp merge_gate_project(options, queries, number) do
    reads = Agent.get(queries, &Enum.count(&1, fn query -> query =~ "SymphonyProject(" end))
    requeued = Agent.get(queries, &Enum.any?(&1, fn query -> query =~ "SymphonySetProjectStatus" end))

    status =
      cond do
        requeued -> "Ready"
        options[:human_decision_changed] == true and reads > 1 -> "Building"
        true -> "Human Review"
      end

    issue_state = if options[:issue_closed] == true and reads > 1, do: "CLOSED", else: "OPEN"
    {:ok, %{status: 200, body: project_response([issue_item("octo/app", number, status, issue_state)])}}
  end

  defp merge_gate_comments(options, issue, sha) do
    base_sha = "base-current"
    review_sha = Map.get(options, :review_sha, sha)

    report = %{
      "outcome" => Map.get(options, :review_outcome, "passed"),
      "sha" => review_sha,
      "base_sha" => base_sha,
      "qa_verification" => %{
        "command" => "make -C elixir all",
        "status" => "passed",
        "evidence" => "Host replay passed.",
        "sha" => review_sha,
        "base_sha" => base_sha,
        "finding_id" => nil
      },
      "findings" => [],
      "resolutions" => []
    }

    marker = "<!-- symphony:report:start:#{Issue.execution_identity(issue)}:1:review:1 -->"
    body = marker <> "\n<!-- symphony:report:json\n" <> Jason.encode!(report) <> "\n-->"
    nodes = if options[:review_report] == :missing, do: [], else: [%{"body" => body, "author" => %{"login" => Map.get(options, :review_author, "agent")}}]
    comments = %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}
    {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"issue" => %{"comments" => comments}}}}}}
  end

  defp merge_gate_base_ref(nil), do: nil
  defp merge_gate_base_ref(oid), do: %{"target" => %{"oid" => oid}}

  defp review_qa_report(sha, base_sha, command) do
    %{
      "outcome" => "passed",
      "sha" => sha,
      "base_sha" => base_sha,
      "criteria" => [],
      "files" => [],
      "changes" => [],
      "verification_command" => command,
      "checks" => [
        %{
          "id" => "qa-test",
          "layer" => "unit",
          "command" => command,
          "status" => "passed",
          "result" => "Tests passed.",
          "evidence" => "Test output captured.",
          "required" => true,
          "reason" => nil
        }
      ],
      "host_checks" => [
        %{
          "name" => command,
          "status" => "passed",
          "evidence" => "Host exit status 0.",
          "source" => "host"
        }
      ],
      "gaps" => [],
      "findings" => [],
      "next_step" => "Continue to Review.",
      "reason" => nil
    }
  end

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
    repository = Map.get(issue.native_ref || %{}, :repository) || Map.get(issue.native_ref || %{}, "repository") || "octo/app"

    %{
      "id" => "PR_pipeline",
      "number" => 107,
      "url" => "https://github.com/#{repository}/pull/107",
      "state" => "OPEN",
      "isDraft" => true,
      "mergedAt" => nil,
      "baseRefName" => "main",
      "headRefName" => issue.branch_name,
      "headRefOid" => "sha-seven",
      "body" => body
    }
  end

  defp pipeline_pull_request_connection(nodes),
    do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}

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

  defp write_projects_workflow!(workspace_root \\ Path.join(System.tmp_dir!(), "symphony_workspaces")) do
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
      workspace:
        root: "#{workspace_root}"
      ---

      Work on {{ issue.identifier }}.
      """
    )

    assert :ok = WorkflowStore.force_reload()
  end

  defp project_repository(repository, source) do
    %{
      "repository" => repository,
      "base_branch" => "main",
      "prepare_command" => "git init -b main && git remote add origin #{source}",
      "required_checks" => ["true"]
    }
  end

  defp create_test_repository!(path, repository) do
    File.mkdir_p!(path)
    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.name", "Test User"])
    git!(path, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(path, "repository.txt"), "#{repository}\n")
    git!(path, ["add", "repository.txt"])
    git!(path, ["commit", "-m", "initial"])
    path
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end

defmodule SymphonyElixir.GitHubProjectsAdapterTest.FakeGitHubProjectsClient do
  def phase_reports(_issue), do: {:ok, []}
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
