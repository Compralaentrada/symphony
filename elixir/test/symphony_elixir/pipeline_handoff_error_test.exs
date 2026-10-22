defmodule SymphonyElixir.PipelineHandoffErrorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Projects.Client

  test "preserves a stale lease when Build handoff fails" do
    root = Path.join(System.tmp_dir!(), "symphony-handoff-error-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    codex_binary = Path.join(root, "fake-codex")
    database_path = Path.join(root, "pipeline.sqlite3")
    previous_database = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    previous_client = Application.fetch_env(:symphony_elixir, :github_projects_client_module)
    File.mkdir_p!(root)

    on_exit(fn ->
      restore_application_env(:pipeline_database_path, previous_database)
      restore_application_env(:github_projects_client_module, previous_client)
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
      String.replace(workflow, "  kind: \"github_projects\"\n", """
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
      """)

    File.write!(Workflow.workflow_file_path(), workflow)
    assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :pipeline_database_path, database_path)
    Application.put_env(:symphony_elixir, :github_projects_client_module, Client)

    sha = String.duplicate("a", 40)

    issue = %Issue{
      id: "octo/app#42",
      identifier: "octo/app#42",
      title: "Preserve handoff errors",
      description: "Keep the original GitHub tool failure.",
      state: "Building",
      url: "https://example.org/octo/app/issues/42",
      labels: ["backend"],
      native_ref: %{repository: "octo/app"}
    }

    task = %{
      "issue_id" => issue.id,
      "generation" => 1,
      "phase" => "build",
      "attempts" => %{"build" => 1},
      "status" => "building",
      "current_sha" => sha
    }

    report = %{
      "outcome" => "ready",
      "summary" => "Build completed.",
      "criteria" => [],
      "changes" => [],
      "checks" => [],
      "risks" => [],
      "next_step" => "Continue to QA.",
      "sha" => sha
    }

    tool_call =
      Jason.encode!(%{
        "id" => 101,
        "method" => "item/tool/call",
        "params" => %{
          "tool" => "github_workflow",
          "callId" => "handoff-call",
          "threadId" => "build-thread",
          "turnId" => "build-turn",
          "arguments" => %{"operation" => "handoff", "outcome" => "ready", "report" => report}
        }
      })

    report_delta =
      Jason.encode!(%{
        "method" => "item/agentMessage/delta",
        "params" => %{
          "threadId" => "build-thread",
          "turnId" => "build-turn",
          "itemId" => "build-output",
          "delta" => Jason.encode!(report)
        }
      })

    completion =
      Jason.encode!(%{
        "method" => "turn/completed",
        "params" => %{
          "threadId" => "build-thread",
          "turn" => %{"id" => "build-turn", "status" => "completed", "items" => []}
        }
      })

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"build-thread"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"build-turn"}}}'
          printf '%s\\n' '#{tool_call}'
          ;;
        5)
          printf '%s\\n' '#{report_delta}'
          printf '%s\\n' '#{completion}'
          exit 0
          ;;
        *) exit 0 ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    assert %{
             "_remote_evidence" => [],
             "_workflow_errors" => [%{"operation" => "handoff", "reason" => ":stale_agent_lease"}],
             "outcome" => "ready"
           } =
             result =
             AgentRunner.run(issue, nil,
               phase: :build,
               pipeline_task: task,
               generation: 1,
               phase_attempt: 1,
               branch: "symphony/mt-42"
             )

    assert {:error, :stale_agent_lease} =
             SymphonyElixir.Pipeline.finish_phase(issue, task, "build", 1, result)

    assert {:error, {:github_workflow_failed, "handoff", "github_projects_api_error"}} =
             SymphonyElixir.Pipeline.finish_phase(
               issue,
               task,
               "build",
               1,
               Map.put(result, "_workflow_errors", [
                 %{"operation" => "handoff", "reason" => "github_projects_api_error"}
               ])
             )
  end

  defp restore_application_env(key, {:ok, value}), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_application_env(key, :error), do: Application.delete_env(:symphony_elixir, key)
end
