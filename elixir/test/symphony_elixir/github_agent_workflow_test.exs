defmodule SymphonyElixir.GitHubAgentWorkflowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.AgentTool
  alias SymphonyElixir.Pipeline.Store

  test "GitHub Issues agents can claim, create a draft PR, and update their report once" do
    initial_state = %{
      comments: [%{"id" => "human-1", "body" => "Human note", "user" => %{"login" => "alice"}}],
      pull_requests: [],
      next_comment_id: 1
    }

    state = Agent.start_link(fn -> initial_state end)
    {:ok, state} = state

    github_rest = fn method, path, _params, body, _settings ->
      Agent.get_and_update(state, fn data ->
        case {method, path} do
          {"GET", "/user"} ->
            {{:ok, %{status: 200, body: %{"login" => "symphony-bot"}}}, data}

          {"GET", "/repos/octo/app/issues/42"} ->
            {{:ok, %{status: 200, body: %{"state" => "open", "html_url" => "https://github.com/octo/app/issues/42"}}}, data}

          {"GET", "/repos/octo/app/git/ref/heads/symphony%2Focto-app-42"} ->
            {{:ok, %{status: 200, body: %{"object" => %{"sha" => String.duplicate("a", 40)}}}}, data}

          {"GET", "/repos/octo/app/issues/42/comments"} ->
            {{:ok, %{status: 200, body: data.comments}}, data}

          {"POST", "/repos/octo/app/issues/42/comments"} ->
            comment = %{
              "id" => "agent-#{data.next_comment_id}",
              "html_url" => "https://github.com/octo/app/issues/42#issuecomment-#{data.next_comment_id}",
              "body" => body["body"],
              "user" => %{"login" => "symphony-bot"}
            }

            next = %{data | comments: data.comments ++ [comment], next_comment_id: data.next_comment_id + 1}
            {{:ok, %{status: 201, body: comment}}, next}

          {"PATCH", "/repos/octo/app/issues/comments/agent-2"} ->
            comments = Enum.map(data.comments, &if(&1["id"] == "agent-2", do: Map.put(&1, "body", body["body"]), else: &1))
            updated = Enum.find(comments, &(&1["id"] == "agent-2"))
            {{:ok, %{status: 200, body: updated}}, %{data | comments: comments}}

          {"GET", "/repos/octo/app/pulls"} ->
            {{:ok, %{status: 200, body: data.pull_requests}}, data}

          {"POST", "/repos/octo/app/pulls"} ->
            pr = %{
              "number" => 9,
              "id" => 9,
              "html_url" => "https://github.com/octo/app/pull/9",
              "state" => "open",
              "draft" => true,
              "head" => %{"ref" => body["head"], "sha" => String.duplicate("a", 40)},
              "base" => %{"ref" => body["base"]},
              "body" => body["body"]
            }

            {{:ok, %{status: 201, body: pr}}, %{data | pull_requests: [pr]}}

          {"PATCH", "/repos/octo/app/pulls/9"} ->
            pull_requests = Enum.map(data.pull_requests, &Map.put(&1, "body", body["body"]))
            {{:ok, %{status: 200, body: List.first(pull_requests)}}, %{data | pull_requests: pull_requests}}
        end
      end)
    end

    issue = %Issue{
      id: "octo/app#42",
      identifier: "octo/app#42",
      title: "Add a feature",
      url: "https://github.com/octo/app/issues/42",
      branch_name: "symphony/octo-app-42",
      state: "open",
      native_ref: %{"repo" => "octo/app", "number" => 42, "node_id" => "issue-node-42"}
    }

    context = %{
      issue: issue,
      lane: :individual,
      task: %{"branch" => issue.branch_name, "base_branch" => "main"},
      generation: 1,
      attempt: 1,
      lease_token: "github-issue-agent-test",
      merge_policy: "human"
    }

    assert :ok = Store.begin_agent_lease(issue.id, context.lease_token)

    opts = [
      agent_context: context,
      tracker_settings: %{kind: "github", provider: %{"repo" => "octo/app", "token" => "private-token"}},
      github_rest: github_rest
    ]

    claim = AgentTool.execute("github_workflow", %{"operation" => "claim"}, opts)
    assert claim["success"], claim["output"]

    report = %{
      "outcome" => "ready",
      "summary" => "Implemented the feature.",
      "criteria" => [],
      "changes" => ["Added the feature."],
      "checks" => [],
      "risks" => [],
      "next_step" => "Review the draft PR.",
      "sha" => String.duplicate("a", 40)
    }

    first = AgentTool.execute("github_workflow", %{"operation" => "handoff", "report" => report}, opts)

    Agent.update(state, fn data ->
      update_in(data.pull_requests, fn [pull_request] -> [Map.update!(pull_request, "body", &(&1 <> "\n\nHuman PR note"))] end)
      |> Map.update!(:comments, fn comments ->
        Enum.map(comments, fn comment ->
          if comment["id"] == "agent-2", do: Map.update!(comment, "body", &(&1 <> "\n\nHuman appendix")), else: comment
        end)
      end)
    end)

    second = AgentTool.execute("github_workflow", %{"operation" => "handoff", "report" => report}, opts)

    assert first["success"], first["output"]
    assert second["success"], second["output"]
    assert get_in(first, ["evidence", "pull_request", "draft"])
    assert get_in(first, ["evidence", "pull_request", "head_sha"]) == report["sha"]
    assert length(Agent.get(state, & &1.pull_requests)) == 1
    assert hd(Agent.get(state, & &1.pull_requests))["body"] =~ "Human PR note"
    assert Enum.count(Agent.get(state, & &1.comments), &String.contains?(&1["body"] || "", "symphony:report")) == 1
    assert Enum.any?(Agent.get(state, & &1.comments), &(&1["body"] == "Human note"))
    assert Enum.any?(Agent.get(state, & &1.comments), &String.contains?(&1["body"] || "", "Human appendix"))
    refute first["output"] =~ "private-token"

    assert :ok = Store.end_agent_lease(issue.id, context.lease_token)
    calls = Agent.get(state, &length(&1.comments))
    stale = AgentTool.execute("github_workflow", %{"operation" => "claim"}, opts)
    refute stale["success"]
    assert Agent.get(state, &length(&1.comments)) == calls
  end

  test "the persistent workpad updates its owned block and preserves human text" do
    alias SymphonyElixir.Pipeline.Store

    {:ok, state} = Agent.start_link(fn -> %{comments: [], next_comment_id: 1} end)

    github_rest = fn method, path, _params, body, _settings ->
      Agent.get_and_update(state, fn data ->
        case {method, path} do
          {"GET", "/user"} ->
            {{:ok, %{status: 200, body: %{"login" => "symphony-bot"}}}, data}

          {"GET", "/repos/octo/app/issues/42/comments"} ->
            {{:ok, %{status: 200, body: data.comments}}, data}

          {"POST", "/repos/octo/app/issues/42/comments"} ->
            comment = %{
              "id" => "workpad-#{data.next_comment_id}",
              "html_url" => "https://github.com/octo/app/issues/42#issuecomment-#{data.next_comment_id}",
              "body" => body["body"],
              "user" => %{"login" => "symphony-bot"}
            }

            updated = %{data | comments: [comment], next_comment_id: data.next_comment_id + 1}
            {{:ok, %{status: 201, body: comment}}, updated}

          {"PATCH", "/repos/octo/app/issues/comments/workpad-1"} ->
            comment = Map.put(hd(data.comments), "body", body["body"])
            {{:ok, %{status: 200, body: comment}}, %{data | comments: [comment]}}
        end
      end)
    end

    issue = %Issue{
      id: "octo/app#42",
      identifier: "octo/app#42",
      url: "https://github.com/octo/app/issues/42",
      native_ref: %{"repo" => "octo/app", "number" => 42}
    }

    context = %{issue: issue, lane: :individual, generation: 1, attempt: 1, lease_token: "workpad-agent"}
    assert :ok = Store.begin_agent_lease(issue.id, context.lease_token)

    opts = [
      agent_context: context,
      tracker_settings: %{kind: "github", provider: %{"repo" => "octo/app", "token" => "private-token"}},
      github_rest: github_rest
    ]

    first = AgentTool.execute("github_workflow", %{"operation" => "workpad", "body" => "### Plan\n- Inspect the issue"}, opts)

    Agent.update(state, fn data ->
      [comment] = data.comments
      %{data | comments: [Map.update!(comment, "body", &(&1 <> "\n\nHuman note"))]}
    end)

    second = AgentTool.execute("github_workflow", %{"operation" => "workpad", "body" => "### Plan\n- Implement the fix"}, opts)

    assert first["success"], first["output"]
    assert second["success"], second["output"]
    assert first["evidence"]["comment"]["id"] == second["evidence"]["comment"]["id"]
    assert length(Agent.get(state, & &1.comments)) == 1
    assert hd(Agent.get(state, & &1.comments))["body"] =~ "- Implement the fix"
    assert hd(Agent.get(state, & &1.comments))["body"] =~ "Human note"

    assert :ok = Store.end_agent_lease(issue.id, context.lease_token)
  end

  test "follow-up issues are linked as native sub-issues and retries reuse the same issue" do
    alias SymphonyElixir.Pipeline.Store

    {:ok, state} = Agent.start_link(fn -> %{follow_up: nil, linked?: false, creates: 0, links: 0} end)
    child = fn body -> %{"id" => 77, "number" => 43, "html_url" => "https://github.com/octo/app/issues/43", "body" => body} end

    github_rest = fn method, path, params, body, _settings ->
      Agent.get_and_update(state, fn data ->
        case {method, path} do
          {"GET", "/search/issues"} ->
            [marker] = Regex.run(~r/<!-- symphony:follow-up:[^>]+-->/, params["q"])

            items =
              if data.follow_up && marker && String.contains?(data.follow_up["body"], marker),
                do: [data.follow_up],
                else: []

            {{:ok, %{status: 200, body: %{"items" => items}}}, data}

          {"POST", "/repos/octo/app/issues"} ->
            issue = child.(body["body"])
            {{:error, :timeout}, %{data | follow_up: issue, creates: data.creates + 1}}

          {"GET", "/repos/octo/app/issues/42/sub_issues"} ->
            issues = if data.linked?, do: [data.follow_up], else: []
            {{:ok, %{status: 200, body: issues}}, data}

          {"POST", "/repos/octo/app/issues/42/sub_issues"} ->
            {{:ok, %{status: 201, body: data.follow_up}}, %{data | linked?: true, links: data.links + 1}}
        end
      end)
    end

    issue = %Issue{
      id: "octo/app#42",
      identifier: "octo/app#42",
      url: "https://github.com/octo/app/issues/42",
      native_ref: %{"repo" => "octo/app", "number" => 42}
    }

    context = %{issue: issue, lane: :individual, generation: 1, attempt: 1, lease_token: "follow-up-agent"}
    assert :ok = Store.begin_agent_lease(issue.id, context.lease_token)

    opts = [
      agent_context: context,
      tracker_settings: %{kind: "github", provider: %{"repo" => "octo/app", "token" => "private-token"}},
      github_rest: github_rest
    ]

    args = %{"operation" => "create_follow_up_issue", "title" => "Track follow-up", "body" => "Follow-up details"}

    first = AgentTool.execute("github_workflow", args, opts)
    second = AgentTool.execute("github_workflow", args, Keyword.put(opts, :agent_context, %{context | attempt: 2}))

    assert first["success"], first["output"]
    assert second["success"], second["output"]
    assert first["evidence"] == second["evidence"]
    assert first["evidence"]["linked"]
    assert first["evidence"]["parent"] == issue.id
    assert Agent.get(state, & &1.creates) == 1
    assert Agent.get(state, & &1.links) == 1

    assert :ok = Store.end_agent_lease(issue.id, context.lease_token)
  end
end
