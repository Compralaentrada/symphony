defmodule SymphonyElixir.GitHubAgentToolPermissionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.AgentTool

  test "phase tools expose only the operations owned by their lane" do
    build = AgentTool.tool_specs(agent_context(:build))
    qa = AgentTool.tool_specs(agent_context(:qa))
    review = AgentTool.tool_specs(agent_context(:review, "auto"))
    individual = AgentTool.tool_specs(agent_context(:individual, "auto"))

    assert workflow_operations(build) == ["claim", "read_workpad", "workpad", "handoff", "create_follow_up_issue"]
    assert workflow_operations(qa) == ["read_workpad", "workpad", "handoff", "create_follow_up_issue"]
    assert workflow_operations(review) == ["read_workpad", "workpad", "handoff", "create_follow_up_issue", "request_merge"]
    refute "request_merge" in workflow_operations(individual)
    refute "read_workpad" in workflow_operations(individual)
  end

  test "GitHub reads are bound to the task repository and raw writes are unavailable" do
    context = agent_context(:build)

    client = fn method, path, _params, _body, _opts ->
      send(self(), {:github_request, method, path})
      {:ok, %{status: 200, body: %{}}}
    end

    allowed =
      AgentTool.execute("github_api", %{"method" => "GET", "path" => "/repos/octo/app/issues/42"},
        agent_context: context,
        github_client: client
      )

    assert allowed["success"]
    assert_received {:github_request, "GET", "/repos/octo/app/issues/42"}

    refute AgentTool.execute("github_api", %{"method" => "GET", "path" => "/repos/other/app/issues/42"},
             agent_context: context,
             github_client: client
           )["success"]

    refute AgentTool.execute("github_api", %{"method" => "POST", "path" => "/repos/octo/app/issues/42/comments"},
             agent_context: context,
             github_client: client
           )["success"]

    refute_received {:github_request, _, _}

    invalid_method =
      AgentTool.execute(
        "github_api",
        %{"method" => "TRACE", "path" => "/user"},
        agent_context: context,
        github_client: fn _method, _path, _params, _body, _opts -> flunk("invalid methods must not reach GitHub") end
      )

    assert Jason.decode!(invalid_method["output"])["error"]["message"] == "`github_api.method` must be GET."
  end

  test "a lane cannot invoke a write owned by another lane" do
    response =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "request_merge", "report" => %{}},
        agent_context: agent_context(:build, "auto"),
        workflow_client: fn _operation, _arguments, _opts -> flunk("unauthorized write reached the client") end
      )

    refute response["success"]
  end

  test "Review reaches the merge gate only when auto is explicit" do
    for context <- [agent_context(:review), Map.delete(agent_context(:review), :merge_policy)] do
      response =
        AgentTool.execute(
          "github_workflow",
          %{"operation" => "request_merge", "report" => %{}},
          agent_context: context,
          workflow_client: fn _context, _operation, _arguments -> flunk("human policy reached the merge gate") end
        )

      refute response["success"]
    end

    response =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "request_merge", "report" => %{}},
        agent_context: agent_context(:review, "auto"),
        workflow_client: fn _context, "request_merge", _arguments -> {:ok, %{"requested" => true}} end
      )

    assert response["success"]
    assert response["evidence"] == %{"requested" => true}
  end

  test "workflow rejects malformed calls and uses the configured GitHub tracker client" do
    assert %{"success" => false} = AgentTool.execute("github_workflow", "not an object", [])

    invalid_result =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "claim"},
        agent_context: agent_context(:build),
        workflow_client: fn _context, _operation, _arguments -> :unexpected end
      )

    assert %{"success" => false} = invalid_result

    for kind <- ["github", "github_projects"] do
      result =
        AgentTool.execute(
          "github_workflow",
          %{"operation" => "claim"},
          agent_context: agent_context(:build),
          tracker_settings: %{kind: kind, provider: %{}}
        )

      assert %{"success" => false} = result
      assert Jason.decode!(result["output"])["error"]["reason"] == ":missing_agent_lease"
    end

    unsupported_tracker =
      AgentTool.execute(
        "github_workflow",
        %{"operation" => "claim"},
        agent_context: agent_context(:build),
        tracker_settings: %{kind: "linear", provider: %{}}
      )

    assert Jason.decode!(unsupported_tracker["output"])["error"]["reason"] == ":github_tracker_required"
  end

  test "GitHub repository scope falls back to issue identity and rejects malformed repository data" do
    issue = %Issue{id: "octo/app#42"}
    fallback_context = %{issue: issue, lane: :qa}

    allowed =
      AgentTool.execute("github_api", %{"method" => "GET", "path" => "/repos/octo/app/issues/42"},
        agent_context: fallback_context,
        github_client: fn _method, _path, _params, _body, _opts -> {:ok, %{status: 200, body: %{}}} end
      )

    assert allowed["success"]

    invalid_issues = [
      %Issue{id: "not-an-issue"},
      %Issue{id: "42", native_ref: %{repository: "octo/.."}},
      %Issue{id: "octo/app#42", native_ref: %{repository: 42}},
      %Issue{id: 42}
    ]

    Enum.each(invalid_issues, fn issue ->
      denied =
        AgentTool.execute("github_api", %{"method" => "GET", "path" => "/user"},
          agent_context: %{issue: issue, lane: :qa},
          github_client: fn _method, _path, _params, _body, _opts -> flunk("invalid repository reached GitHub") end
        )

      assert denied["success"] == false
    end)
  end

  defp workflow_operations(specs) do
    specs
    |> Enum.find(&(&1["name"] == "github_workflow"))
    |> get_in(["inputSchema", "properties", "operation", "enum"])
  end

  defp agent_context(lane, merge_policy \\ "human") do
    %{
      issue: %Issue{
        id: "octo/app#42",
        identifier: "octo/app#42",
        branch_name: "symphony/octo-app-42",
        native_ref: %{repository: "octo/app", base_branch: "main"}
      },
      lane: lane,
      merge_policy: merge_policy,
      tracker_kind: "github_projects"
    }
  end
end
