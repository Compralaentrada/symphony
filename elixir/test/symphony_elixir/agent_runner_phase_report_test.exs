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
            "turn" => %{
              "id" => "review-output-turn",
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
            "itemId" => "report-item",
            "delta" => "**Potential improvements**\n\nThe review is complete, with one suggestion."
          }
        })

      report_delta =
        Jason.encode!(%{
          "method" => "item/agentMessage/delta",
          "params" => %{"itemId" => "report-item", "delta" => Jason.encode!(report)}
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
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"structured-phase-report-thread"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"structured-phase-report-turn"}}}'
            if printf '%s' "$line" | grep -q '"outputSchema"'; then
              printf '%s\\n' '#{report_delta}'
            else
              printf '%s\\n' '#{prose_delta}'
            fi
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"structured-phase-report-retry"}}}'
            printf '%s\\n' '#{prose_delta}'
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
        title: "Return a review report",
        description: "Review the accepted commit and return the phase report.",
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

      turn_params =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["method"] == "turn/start"))
        |> Map.fetch!("params")

      schema = Map.fetch!(turn_params, "outputSchema")
      assert schema["type"] == "object"
      assert "outcome" in schema["required"]
      assert "findings" in schema["required"]
      assert get_in(schema, ["properties", "findings", "items", "required"]) == ["id", "reproduction", "criterion"]
    after
      File.rm_rf(test_root)
    end
  end
end
