defmodule SymphonyElixir.AgentRunnerHandoffRetryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pipeline

  @sha String.duplicate("a", 40)

  test "retries a rejected handoff once and finishes with its evidence" do
    %{issue: issue, task: task, result: result, turn_starts: turn_starts} =
      run_handoff_attempts([tool_failure(":invalid_github_pull_request_body"), tool_success()])

    assert length(turn_starts) == 2
    correction_prompt = get_in(Enum.at(turn_starts, 1), ["params", "input", Access.at(0), "text"])
    assert correction_prompt =~ "The previous GitHub handoff was rejected"
    assert List.last(result["_remote_evidence"]) == handoff_evidence()
    refute Map.has_key?(result, "_workflow_errors")
    assert :ok = Pipeline.finish_phase(issue, task, "review", 1, result)
  end

  test "keeps a second rejected handoff as a phase failure" do
    %{issue: issue, task: task, result: result, turn_starts: turn_starts} =
      run_handoff_attempts([tool_failure(":first_rejection"), tool_failure(":second_rejection")])

    assert length(turn_starts) == 2
    assert Enum.map(result["_workflow_errors"], & &1["reason"]) == [":first_rejection", ":second_rejection"]

    assert {:error, {:github_workflow_failed, "handoff", ":second_rejection"}} =
             Pipeline.finish_phase(issue, task, "review", 1, result)
  end

  test "retries when the agent returns a report without handoff evidence" do
    %{result: result, turn_starts: turn_starts} =
      run_handoff_attempts([tool_success()], first_handoff: false)

    assert length(turn_starts) == 2
    correction_prompt = get_in(Enum.at(turn_starts, 1), ["params", "input", Access.at(0), "text"])
    assert correction_prompt =~ "No successful GitHub handoff comment was recorded"
    assert List.last(result["_remote_evidence"]) == handoff_evidence()
  end

  test "does not repeat a successful handoff when its evidence is missing" do
    %{issue: issue, task: task, result: result, turn_starts: turn_starts} =
      run_handoff_attempts([tool_success_without_evidence()])

    assert length(turn_starts) == 1
    assert result["_remote_evidence"] == []

    assert {:error, :github_handoff_comment_evidence_missing} =
             Pipeline.finish_phase(issue, task, "review", 1, result)
  end

  defp run_handoff_attempts(tool_results, opts \\ []) do
    first_handoff? = Keyword.get(opts, :first_handoff, true)
    root = Path.join(System.tmp_dir!(), "symphony-agent-handoff-retry-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    codex_binary = Path.join(root, "fake-codex")
    trace_file = Path.join(root, "codex-input.trace")
    database_path = Path.join(root, "pipeline.sqlite3")
    previous_database = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    File.mkdir_p!(root)

    on_exit(fn ->
      restore_application_env(:pipeline_database_path, previous_database)
      File.rm_rf!(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github_projects",
      tracker_active_states: ["Ready", "Building", "QA", "Review", "Human Review"],
      tracker_terminal_states: ["closed", "Dropped"],
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      hook_after_create: required_skill_fixture_hook()
    )

    workflow = File.read!(Workflow.workflow_file_path())

    workflow =
      String.replace(
        workflow,
        "  kind: \"github_projects\"\n",
        """
          kind: "github_projects"
          provider:
            owner: acme
            project_number: 1
            token: test-token
            repositories:
              - repository: octo/app
                base_branch: main
                prepare_command: "true"
                required_checks: ["true"]
        """,
        global: false
      )

    File.write!(Workflow.workflow_file_path(), workflow)
    assert :ok = WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :pipeline_database_path, database_path)

    report = %{
      "outcome" => "passed",
      "summary" => "Review passed",
      "findings" => [],
      "resolutions" => [],
      "next_step" => "Continue to Human Review.",
      "reason" => nil,
      "sha" => @sha
    }

    first_turn = "handoff-retry-first"
    second_turn = "handoff-retry-second"
    thread_id = "handoff-retry-thread"
    first_operation = if first_handoff?, do: "handoff", else: "workpad"
    first_tool_call = "printf '%s\\n' '#{tool_call(thread_id, first_turn, report, 101, first_operation)}'\n"

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> '#{trace_file}'
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"#{thread_id}"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"#{first_turn}"}}}'
          #{first_tool_call}printf '%s\\n' '#{report_delta(thread_id, first_turn, report)}'
          printf '%s\\n' '#{turn_completion(thread_id, first_turn)}'
          ;;
        5) ;;
        6)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"#{second_turn}"}}}'
          printf '%s\\n' '#{tool_call(thread_id, second_turn, report, 102)}'
          printf '%s\\n' '#{report_delta(thread_id, second_turn, report)}'
          printf '%s\\n' '#{turn_completion(thread_id, second_turn)}'
          ;;
        7) exit 0 ;;
        *) ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    issue = %Issue{
      id: "octo/app#42",
      identifier: "octo/app#42",
      title: "Recover a rejected handoff",
      description: "A rejected handoff should get one correction turn.",
      state: "Review",
      url: "https://github.com/octo/app/issues/42",
      labels: ["backend"],
      native_ref: %{repository: "octo/app"}
    }

    counter = :counters.new(1, [])

    tool_executor = fn
      "github_workflow", %{"operation" => "handoff"} ->
        :counters.add(counter, 1, 1)
        attempt = :counters.get(counter, 1)
        Enum.at(tool_results, attempt - 1)

      "github_workflow", %{"operation" => "workpad"} ->
        tool_success_workpad()
    end

    task = %{
      "issue_id" => issue.id,
      "generation" => 1,
      "phase" => "review",
      "attempts" => %{"review" => 1},
      "status" => "review",
      "current_sha" => @sha,
      "prior_findings" => []
    }

    result =
      AgentRunner.run(issue, nil,
        phase: :review,
        branch: "symphony/octo-app-42",
        sha: @sha,
        tool_executor: tool_executor
      )

    turn_starts =
      trace_file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim_leading(&1, "JSON:"))
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["method"] == "turn/start"))

    %{issue: issue, task: task, result: result, turn_starts: turn_starts}
  end

  defp tool_call(thread_id, turn_id, report, id, operation \\ "handoff") do
    Jason.encode!(%{
      "id" => id,
      "method" => "item/tool/call",
      "params" => %{
        "tool" => "github_workflow",
        "callId" => "handoff-#{id}",
        "threadId" => thread_id,
        "turnId" => turn_id,
        "arguments" => %{
          "operation" => operation,
          "outcome" => "passed",
          "report" => report,
          "body" => "## Review report\n\nReview passed."
        }
      }
    })
  end

  defp report_delta(thread_id, turn_id, report) do
    Jason.encode!(%{
      "method" => "item/agentMessage/delta",
      "params" => %{
        "threadId" => thread_id,
        "turnId" => turn_id,
        "itemId" => "review-report",
        "delta" => Jason.encode!(report)
      }
    })
  end

  defp turn_completion(thread_id, turn_id) do
    Jason.encode!(%{
      "method" => "turn/completed",
      "params" => %{
        "threadId" => thread_id,
        "turn" => %{"id" => turn_id, "status" => "completed", "items" => []}
      }
    })
  end

  defp tool_failure(reason) do
    output = Jason.encode!(%{"error" => %{"reason" => reason}})
    %{"success" => false, "output" => output}
  end

  defp tool_success do
    evidence = handoff_evidence()
    output = Jason.encode!(%{"success" => true, "evidence" => evidence})
    %{"success" => true, "output" => output, "evidence" => evidence}
  end

  defp tool_success_without_evidence do
    output = Jason.encode!(%{"success" => true})
    %{"success" => true, "output" => output}
  end

  defp tool_success_workpad do
    evidence = %{
      "issue" => %{"id" => "octo/app#42"},
      "comment" => %{"id" => "workpad-comment", "url" => "https://github.com/octo/app/issues/42#issuecomment-2"}
    }

    output = Jason.encode!(%{"success" => true, "evidence" => evidence})
    %{"success" => true, "output" => output, "evidence" => evidence}
  end

  defp handoff_evidence do
    %{
      "outcome" => "passed",
      "comment" => %{"id" => "handoff-comment", "url" => "https://github.com/octo/app/issues/42#issuecomment-1"},
      "project_item" => %{"id" => "project-item", "status" => "Human Review"},
      "pull_request" => %{"url" => "https://github.com/octo/app/pull/42", "head_sha" => @sha}
    }
  end

  defp restore_application_env(key, {:ok, value}), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_application_env(key, :error), do: Application.delete_env(:symphony_elixir, key)
end
