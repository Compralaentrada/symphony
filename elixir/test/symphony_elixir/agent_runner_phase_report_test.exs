defmodule SymphonyElixir.AgentRunnerPhaseReportTest do
  use SymphonyElixir.TestSupport

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

      report_delta = fn report ->
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "qa-report", "delta" => Jason.encode!(report)}
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
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"qa-report-thread"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"qa-report-turn"}}}'
            printf '%s\\n' '#{report_delta.(invalid_report)}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"qa-report-correction"}}}'
            printf '%s\\n' '#{report_delta.(report)}'
            printf '%s\\n' '{"method":"turn/completed"}'
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
        description: "Review the accepted change and return the QA phase report.",
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

      prompts =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(&get_in(&1, ["params", "input", Access.at(0), "text"]))

      assert length(prompts) == 2
      assert hd(prompts) =~ "Each finding must include the exact keys id, reproduction, and criterion as non-empty strings."
      assert hd(prompts) =~ "Use the Humanizer guidance for report values"
      refute hd(prompts) =~ "- `code-review`"
      assert Enum.at(prompts, 1) =~ "The previous response did not match the pipeline's required phase report."
    after
      File.rm_rf(test_root)
    end
  end

  test "recovers from a prose review before returning the final phase report" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-phase-report-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(test_root)

      report = %{
        "outcome" => "ready",
        "summary" => "Build complete",
        "criteria" => ["The issue is implemented."],
        "changes" => ["Updated the implementation."],
        "checks" => [],
        "risks" => "The live smoke was not run.",
        "next_step" => "Continue to QA.",
        "sha" => String.duplicate("a", 40)
      }

      review_text =
        """
        **Potential improvements**

        The separate modules may justify separate maps, but they can drift.
        - **Stale helper arguments — baseline smell.** In `pipeline.ex`, `status_value(_task, status)` and `issue_status_value(_issue, status)` ignore their first arguments and only look up `@statuses[status]`. Dropping those arguments and simplifying the single-use `issue_status_value` wrapper would make the new fixed mapping clearer.

        The merge commit brings in `origin/main`; I found no merge-resolution-specific standards issue.
        """

      review =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "report-item", "delta" => review_text}
        })

      report_json = Jason.encode!(report)
      {report_first_half, report_second_half} = String.split_at(report_json, div(byte_size(report_json), 2))

      final_report_first_half =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "report-item", "delta" => report_first_half}
        })

      final_report_second_half =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "report-item", "delta" => report_second_half}
        })

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"phase-report-thread"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"phase-report-turn"}}}'
            printf '%s\\n' '#{review}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"phase-report-retry"}}}'
            printf '%s\\n' '#{final_report_first_half}'
            printf '%s\\n' '#{final_report_second_half}'
            printf '%s\\n' '{"method":"turn/completed"}'
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
        title: "Return a phase report",
        description: "Complete the implementation and return the phase report.",
        state: "Building",
        url: "https://example.org/issues/MT-PHASE-REPORT",
        labels: ["backend"]
      }

      result = AgentRunner.run(issue, nil, phase: :build, branch: "symphony/mt-phase-report")

      assert %{"outcome" => "ready", "summary" => "Build complete"} = result
      assert result["risks"] == ["The live smoke was not run."]
    after
      File.rm_rf(test_root)
    end
  end
end
