defmodule SymphonyElixir.GitHubProjectsAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Projects.{Adapter, Client}
  alias SymphonyElixir.GitHubProjectsAdapterTest.FakeGitHubProjectsClient

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

  test "Review cannot hand off unresolved prior findings to Human Review" do
    finding = %{"id" => "QA-1", "reproduction" => "Run the failing case.", "criterion" => "The acceptance criterion passes."}
    context = %{task: %{"prior_findings" => [finding]}}
    report = %{"outcome" => "passed", "findings" => [], "resolutions" => []}

    assert %{"outcome" => "changes_requested", "findings" => [^finding]} =
             Client.normalize_agent_report_for_test(report, "review", context)

    assert %{"outcome" => "passed", "findings" => []} =
             Client.normalize_agent_report_for_test(%{report | "resolutions" => [finding["id"]]}, "review", context)
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
