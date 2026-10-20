defmodule SymphonyElixir.AgentRunnerSkillPreflightTest do
  use SymphonyElixir.TestSupport

  test "agent runner stops before launching Codex when a required repo skill is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-skill-preflight-#{System.unique_integer([:positive])}"
      )

    codex_binary = Path.join(test_root, "fake-codex")
    launch_marker = Path.join(test_root, "codex-started")

    try do
      File.mkdir_p!(test_root)
      File.write!(codex_binary, "#!/bin/sh\nprintf started > #{launch_marker}\n")
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(test_root, "workspaces"),
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "GH-2-missing-skill",
        title: "Require repo skills before work",
        state: "In Progress",
        labels: ["ready-for-agent"]
      }

      assert_raise RuntimeError, ~r/required_skill_unavailable/, fn -> AgentRunner.run(issue) end
      refute File.exists?(launch_marker)
    after
      File.rm_rf(test_root)
    end
  end
end
