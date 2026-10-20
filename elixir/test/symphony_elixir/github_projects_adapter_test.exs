defmodule SymphonyElixir.GitHubProjectsAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Projects.{Adapter, Client}
  alias SymphonyElixir.GitHubProjectsAdapterTest.FakeGitHubProjectsClient

  test "tracker selects the GitHub Projects adapter" do
    assert {:ok, Adapter} =
             Tracker.adapter_for_kind("github_projects")
  end

  test "tracker lifecycle callbacks delegate claim, completion, and intervention blocking" do
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

    binding = Tracker.bind_agent_tools()
    assert binding.adapter == Adapter
    assert [%{"name" => "github_api"}] = binding.tool_specs
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
        github_client: fn _method, _path, _params, _body, opts ->
          assert get_in(opts, [:tracker_settings, :provider, "repo"]) == nil
          {:ok, %{status: 200, body: %{"login" => "test-user"}}}
        end
      )

    assert fallback_tool_result["success"]

    issue = %Issue{id: "octo/app#7", identifier: "octo/app#7", state: "Ready"}

    assert :ok = Tracker.claim_issue(issue)
    assert_receive {:projects_claim, ^issue}

    assert :ok = Tracker.complete_issue(issue)
    assert_receive {:projects_complete, ^issue}

    assert :ok = Tracker.block_issue(issue, "operator input required")
    assert_receive {:projects_block, ^issue, "operator input required"}

    assert :ok = Tracker.set_pipeline_status(issue, :done)
    assert_receive {:projects_pipeline_status, ^issue, :done, nil}
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
    missing_token = tracker_settings(%{"token" => "$SYMPHONY_GH6_MISSING_TOKEN"})

    assert {:error, {:invalid_github_projects_settings, :missing_token}} =
             Client.validate_settings(missing_token)

    assert {:error, {:invalid_github_projects_settings, :required_labels_not_supported}} =
             Client.validate_settings(%{settings | required_labels: ["ready-for-agent"]})

    assert {:error, {:invalid_github_projects_settings, :terminal_states_must_preserve_requeue_and_include_closed}} =
             Client.validate_settings(%{settings | terminal_states: ["closed", "Done"]})
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
        "status_values" => statuses,
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
          %{"repository" => "octo/app", "base_branch" => "main", "prepare_command" => "true"},
          %{"repository" => "octo/docs", "base_branch" => "main", "prepare_command" => "true"}
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

  test "closed linked issues become terminal and their Project item moves to Done" do
    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["Ready", "Building"], tracker_settings(), fn
               query, variables, _settings ->
                 if query =~ "updateProjectV2ItemFieldValue" do
                   assert variables["optionId"] == "option-done"
                   {:ok, %{status: 200, body: %{"data" => %{"updated" => true}}}}
                 else
                   {:ok, %{status: 200, body: project_response([issue_item("octo/app", 7, "Ready", "CLOSED")])}}
                 end
             end)

    assert issue.state == "closed"
    refute issue.dispatchable
  end

  test "closed linked issues without a Project status still move to Done" do
    closed_item =
      "octo/app"
      |> issue_item(7, "Ready", "CLOSED")
      |> put_in(["fieldValues", "nodes"], [])

    assert {:ok, [issue]} =
             Client.fetch_issues_by_states_for_test(["closed"], tracker_settings(), fn
               query, variables, _settings ->
                 if query =~ "updateProjectV2ItemFieldValue" do
                   assert variables["optionId"] == "option-done"
                   {:ok, %{status: 200, body: %{"data" => %{"updated" => true}}}}
                 else
                   {:ok, %{status: 200, body: project_response([closed_item])}}
                 end
             end)

    assert issue.state == "closed"
    refute issue.dispatchable
  end

  test "an unconfigured repository is blocked with an actionable issue comment" do
    calls = Agent.start_link(fn -> [] end) |> elem(1)

    assert {:ok, []} =
             Client.fetch_issues_by_states_for_test(["Ready"], tracker_settings(), fn
               query, variables, _settings ->
                 Agent.update(calls, &[{query, variables} | &1])

                 if query =~ "updateProjectV2ItemFieldValue" or query =~ "addComment" do
                   {:ok, %{status: 200, body: %{"data" => %{"updated" => true}}}}
                 else
                   {:ok, %{status: 200, body: project_response([issue_item("other/repo", 8, "Ready")])}}
                 end
             end)

    calls = Agent.get(calls, &Enum.reverse/1)
    assert Enum.count(calls, fn {query, _} -> query =~ "updateProjectV2ItemFieldValue" end) == 1
    assert Enum.count(calls, fn {query, _} -> query =~ "addComment" end) == 1
    {_, comment} = Enum.find(calls, fn {query, _} -> query =~ "addComment" end)
    assert comment["body"] =~ "No repository profile is configured for other/repo"
    assert comment["body"] =~ "tracker.provider.repositories"
  end

  test "issues with the same number in different repositories have distinct identities" do
    settings =
      tracker_settings(%{
        "repositories" => [
          %{"repository" => "octo/app", "base_branch" => "main", "prepare_command" => "true"},
          %{"repository" => "octo/docs", "base_branch" => "main", "prepare_command" => "true"}
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

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "github_projects",
      required_labels: [],
      active_states: ["Ready", "Building"],
      terminal_states: ["closed"],
      provider:
        Map.merge(
          %{
            "owner" => "acme",
            "project_number" => 12,
            "status_field" => "Status",
            "status_values" => %{
              "ready" => "Ready",
              "building" => "Building",
              "blocked" => "Blocked",
              "done" => "Done"
            },
            "repositories" => [
              %{
                "repository" => "octo/app",
                "base_branch" => "main",
                "prepare_command" => "true"
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
                    %{"id" => "option-ready", "name" => "Ready"},
                    %{"id" => "option-building", "name" => "Building"},
                    %{"id" => "option-blocked", "name" => "Blocked"},
                    %{"id" => "option-done", "name" => "Done"}
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
        "labels" => %{"nodes" => [%{"name" => "Bug"}]}
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
        active_states: [Ready, Building]
        terminal_states: [closed]
        provider:
          owner: acme
          project_number: 12
          status_field: Status
          status_values: {ready: Ready, building: Building, blocked: Blocked, done: Done}
          repositories:
            - repository: octo/app
              base_branch: main
              prepare_command: "true"
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

  defp notify(message) do
    send(Application.fetch_env!(:symphony_elixir, :projects_lifecycle_test_owner), message)
    :ok
  end

  defp notify(message, result) do
    send(Application.fetch_env!(:symphony_elixir, :projects_lifecycle_test_owner), message)
    result
  end
end
