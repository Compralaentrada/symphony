defmodule SymphonyElixir.AgentRunnerPhaseReportTest do
  use SymphonyElixir.TestSupport

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
