defmodule SymphonyElixir.AgentRunnerPhaseReportTest do
  use SymphonyElixir.TestSupport

  test "does not treat a failed completed turn as a phase report" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-failed-phase-turn-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      File.mkdir_p!(test_root)

      invalid_delta =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "review-output", "delta" => "The review is complete, with one concern."}
        })

      failed_completion =
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "threadId" => "failed-phase-thread",
            "turn" => %{
              "id" => "failed-phase-turn",
              "status" => "failed",
              "error" => %{"message" => "The final output did not satisfy its schema."}
            }
          }
        })

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> '#{trace_file}'
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"failed-phase-thread"}}}' ;;
          4|5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"failed-phase-turn"}}}'
            printf '%s\\n' '#{invalid_delta}'
            printf '%s\\n' '#{failed_completion}'
            ;;
          *) ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: required_skill_fixture_hook(),
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-failed-phase-turn",
        identifier: "MT-FAILED-PHASE-TURN",
        title: "Return a phase report",
        description: "Review the accepted change and return a phase report.",
        state: "Review",
        url: "https://example.org/issues/MT-FAILED-PHASE-TURN",
        labels: ["backend"]
      }

      assert_raise RuntimeError, ~r/turn_not_completed/, fn ->
        AgentRunner.run(issue, nil,
          phase: :review,
          branch: "symphony/mt-failed-phase-turn",
          sha: String.duplicate("a", 40)
        )
      end

      turn_starts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))

      assert length(turn_starts) == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "Build waits for its own turn when another thread completes first" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-build-foreign-turn-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      File.mkdir_p!(test_root)

      report = %{
        "outcome" => "ready",
        "summary" => "Build completed",
        "criteria" => ["The requested change is implemented."],
        "changes" => ["Updated the implementation."],
        "checks" => ["mix test"],
        "risks" => [],
        "next_step" => "Continue to QA.",
        "reason" => nil,
        "sha" => String.duplicate("b", 40)
      }

      foreign_delta =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{
            "threadId" => "review-subagent-thread",
            "turnId" => "review-subagent-turn",
            "itemId" => "review-subagent-output",
            "delta" => "## Spec\n\n- Markdown review finding; this is not a phase report."
          }
        })

      foreign_completion =
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "threadId" => "review-subagent-thread",
            "turn" => %{"id" => "review-subagent-turn", "status" => "completed", "items" => []}
          }
        })

      unidentified_completion = Jason.encode!(%{"method" => "turn/completed"})

      foreign_failure =
        Jason.encode!(%{
          "method" => "turn/failed",
          "params" => %{
            "threadId" => "review-subagent-thread",
            "turn" => %{
              "id" => "review-subagent-turn",
              "status" => "failed",
              "error" => %{"message" => "The review subagent failed."}
            }
          }
        })

      foreign_cancellation =
        Jason.encode!(%{
          "method" => "turn/cancelled",
          "params" => %{
            "threadId" => "review-subagent-thread",
            "turn" => %{"id" => "review-subagent-turn", "status" => "cancelled"}
          }
        })

      report_delta =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{
            "threadId" => "build-root-thread",
            "turnId" => "build-root-turn",
            "itemId" => "build-root-output",
            "delta" => Jason.encode!(report)
          }
        })

      completion =
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "threadId" => "build-root-thread",
            "turn" => %{"id" => "build-root-turn", "status" => "completed", "items" => []}
          }
        })

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> '#{trace_file}'
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"build-root-thread"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"build-root-turn"}}}'
            printf '%s\\n' '#{foreign_delta}'
            printf '%s\\n' '#{unidentified_completion}'
            printf '%s\\n' '#{foreign_failure}'
            printf '%s\\n' '#{foreign_cancellation}'
            printf '%s\\n' '#{foreign_completion}'
            printf '%s\\n' '#{report_delta}'
            printf '%s\\n' '#{completion}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: required_skill_fixture_hook(),
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-build-foreign-turn",
        identifier: "MT-BUILD-FOREIGN-TURN",
        title: "Return the Build report",
        description: "Implement the change and return the Build phase report.",
        state: "Building",
        url: "https://example.org/issues/MT-BUILD-FOREIGN-TURN",
        labels: ["backend"]
      }

      assert %{"outcome" => "ready", "summary" => "Build completed"} =
               AgentRunner.run(issue, nil,
                 phase: :build,
                 branch: "symphony/mt-build-foreign-turn"
               )

      turn_starts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))

      assert length(turn_starts) == 1
    after
      File.rm_rf(test_root)
    end
  end

  test "QA phase corrects schema-invalid findings before returning a report" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-qa-phase-report-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      File.mkdir_p!(test_root)

      report = %{
        "outcome" => "passed",
        "summary" => "QA passed",
        "criteria" => ["The implementation meets the acceptance criterion."],
        "changes" => [],
        "checks" => [],
        "findings" => [],
        "next_step" => "Continue to Review.",
        "sha" => String.duplicate("a", 40)
      }

      invalid_report = %{
        "outcome" => "changes_requested",
        "summary" => "QA found a defect",
        "criteria" => ["The implementation meets the acceptance criterion."],
        "changes" => [],
        "checks" => [],
        "findings" => [
          %{
            "id" => "QA-1",
            "description" => "A defect blocks the acceptance criterion.",
            "location" => "lib/example.ex:10",
            "reproduction_steps" => "Run the failing scenario.",
            "violated_criterion" => "The implementation meets the acceptance criterion."
          }
        ],
        "next_step" => "Fix QA-1 and submit a new Build delivery.",
        "sha" => report["sha"]
      }

      report_delta = fn report, turn_id ->
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{
            "threadId" => "qa-report-thread",
            "turnId" => turn_id,
            "itemId" => "qa-report",
            "delta" => Jason.encode!(report)
          }
        })
      end

      turn_completion = fn turn_id ->
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "threadId" => "qa-report-thread",
            "turn" => %{"id" => turn_id, "status" => "completed", "items" => []}
          }
        })
      end

      foreign_review_delta =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{
            "threadId" => "qa-review-subagent-thread",
            "turnId" => "qa-review-subagent-turn",
            "itemId" => "qa-review-subagent-output",
            "delta" => "## Spec\n\n- This review prose is not the QA phase report."
          }
        })

      foreign_review_completion =
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "threadId" => "qa-review-subagent-thread",
            "turn" => %{
              "id" => "qa-review-subagent-turn",
              "status" => "completed",
              "items" => []
            }
          }
        })

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> '#{trace_file}'
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"qa-report-thread"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"qa-report-turn"}}}'
            printf '%s\\n' '#{report_delta.(invalid_report, "qa-report-turn")}'
            printf '%s\\n' '#{turn_completion.("qa-report-turn")}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"qa-report-correction"}}}'
            printf '%s\\n' '#{report_delta.(report, "qa-report-correction")}'
            printf '%s\\n' '#{foreign_review_delta}'
            printf '%s\\n' '#{foreign_review_completion}'
            printf '%s\\n' '#{turn_completion.("qa-report-correction")}'
            exit 0
            ;;
          *) ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: required_skill_fixture_hook(),
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-qa-phase-report",
        identifier: "MT-QA-PHASE-REPORT",
        title: "Return a QA phase report",
        description: "Examiner la modification acceptée et fournir le rapport QA.",
        state: "QA",
        url: "https://example.org/issues/MT-QA-PHASE-REPORT",
        labels: ["backend"]
      }

      result =
        AgentRunner.run(issue, nil,
          phase: :qa,
          branch: "symphony/mt-qa-phase-report",
          sha: report["sha"],
          required_checks: []
        )

      assert %{"outcome" => "passed", "findings" => []} = result

      turn_starts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))

      prompts = Enum.map(turn_starts, &get_in(&1, ["params", "input", Access.at(0), "text"]))

      assert length(prompts) == 2
      assert hd(prompts) =~ "Each finding must include the exact keys id, reproduction, and criterion as non-empty strings."
      assert hd(prompts) =~ "Use the Humanizer guidance for report values"
      assert hd(prompts) =~ "Write report values in English"
      refute hd(prompts) =~ "- `code-review`"
      assert Enum.at(prompts, 1) =~ "The previous response did not match the pipeline's required phase report."
      assert Enum.all?(turn_starts, &is_map(get_in(&1, ["params", "outputSchema"])))
      assert get_in(hd(turn_starts), ["params", "outputSchema", "properties", "findings", "items", "required"]) == ["id", "reproduction", "criterion"]
    after
      File.rm_rf(test_root)
    end
  end

  test "constrains phase reports with the app-server JSON schema" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-phase-report-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      File.mkdir_p!(test_root)

      report = %{
        "outcome" => "passed",
        "summary" => "Review passed",
        "findings" => [],
        "resolutions" => [],
        "next_step" => "Continue to Human Review.",
        "sha" => String.duplicate("a", 40)
      }

      prose_delta =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{
            "threadId" => "structured-phase-report-thread",
            "turnId" => "structured-phase-report-turn",
            "itemId" => "report-item",
            "delta" => "**Potential improvements**\n\nThe review is complete, with one suggestion."
          }
        })

      report_delta =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{
            "threadId" => "structured-phase-report-thread",
            "turnId" => "structured-phase-report-retry",
            "itemId" => "report-item",
            "delta" => Jason.encode!(report)
          }
        })

      turn_completion = fn turn_id ->
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "threadId" => "structured-phase-report-thread",
            "turn" => %{"id" => turn_id, "status" => "completed", "items" => []}
          }
        })
      end

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> '#{trace_file}'
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"structured-phase-report-thread"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"structured-phase-report-turn"}}}'
            printf '%s\\n' '#{prose_delta}'
            printf '%s\\n' '#{turn_completion.("structured-phase-report-turn")}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"structured-phase-report-retry"}}}'
            printf '%s\\n' '#{report_delta}'
            printf '%s\\n' '#{turn_completion.("structured-phase-report-retry")}'
            exit 0
            ;;
          *) ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: required_skill_fixture_hook(),
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-phase-report",
        identifier: "MT-PHASE-REPORT",
        title: "Return a review report",
        description: "Publish readable Markdown in GitHub comments, not raw JSON. Review the accepted commit and return the phase report.",
        state: "Review",
        url: "https://example.org/issues/MT-PHASE-REPORT",
        labels: ["backend"]
      }

      result =
        AgentRunner.run(issue, nil,
          phase: :review,
          branch: "symphony/mt-phase-report",
          sha: report["sha"]
        )

      assert %{"outcome" => "passed", "summary" => "Review passed"} = result

      turn_starts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))

      assert length(turn_starts) == 2
      [initial_turn, correction_turn] = turn_starts
      assert get_in(initial_turn, ["params", "input", Access.at(0), "text"]) =~ "Do not invoke the repository's `code-review` skill or its Markdown report format"

      assert get_in(initial_turn, ["params", "input", Access.at(0), "text"]) =~
               "The task's Markdown requirement applies only to GitHub comments; this response is the internal phase result."

      assert get_in(correction_turn, ["params", "input", Access.at(0), "text"]) =~ "Do not include headings, bullets, Markdown, code fences, or text outside the JSON object."

      assert get_in(correction_turn, ["params", "input", Access.at(0), "text"]) =~
               "The task's Markdown requirement applies only to GitHub comments; this response is the internal phase result."

      schema = get_in(initial_turn, ["params", "outputSchema"])
      assert schema["type"] == "object"
      assert "outcome" in schema["required"]
      assert "findings" in schema["required"]
      assert get_in(schema, ["properties", "findings", "items", "required"]) == ["id", "reproduction", "criterion"]
      assert is_map(get_in(correction_turn, ["params", "outputSchema"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "Finalize phase accepts a merged report with its schema" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-finalize-phase-report-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      File.mkdir_p!(test_root)

      report = %{
        "outcome" => "merged",
        "summary" => "The merged pull request is confirmed.",
        "sha" => String.duplicate("c", 40),
        "next_step" => "Done."
      }

      report_delta =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{
            "threadId" => "finalize-report-thread",
            "turnId" => "finalize-report-turn",
            "itemId" => "finalize-report",
            "delta" => Jason.encode!(report)
          }
        })

      turn_completion =
        Jason.encode!(%{
          "method" => "turn/completed",
          "params" => %{
            "threadId" => "finalize-report-thread",
            "turn" => %{
              "id" => "finalize-report-turn",
              "status" => "completed",
              "items" => []
            }
          }
        })

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> '#{trace_file}'
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"finalize-report-thread"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"finalize-report-turn"}}}'
            printf '%s\\n' '#{report_delta}'
            printf '%s\\n' '#{turn_completion}'
            exit 0
            ;;
          *) ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: required_skill_fixture_hook(),
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "octo/app#107",
        identifier: "octo/app#107",
        title: "Confirm merged delivery",
        description: "Verify the human-merged pull request.",
        state: "closed",
        url: "https://github.com/octo/app/issues/107",
        labels: ["backend"]
      }

      assert %{"outcome" => "merged", "sha" => sha} =
               AgentRunner.run(issue, nil,
                 phase: :finalize,
                 branch: "symphony/octo-app-107",
                 base_branch: "main",
                 pr_number: 107,
                 sha: report["sha"]
               )

      assert sha == report["sha"]

      turn_start =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["method"] == "turn/start"))

      schema = get_in(turn_start, ["params", "outputSchema"])
      assert Enum.sort(schema["required"]) == Enum.sort(["outcome", "summary", "sha", "next_step"])
      assert get_in(schema, ["properties", "outcome", "enum"]) == ["merged"]
    after
      File.rm_rf(test_root)
    end
  end
end
