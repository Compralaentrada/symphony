defmodule SymphonyElixir.AgentRunnerSkillPreflightTest do
  use SymphonyElixir.TestSupport

  test "agent runner stops before launching Codex when autonomous TDD is missing from Build" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-skill-preflight-#{System.unique_integer([:positive])}"
      )

    codex_binary = Path.join(test_root, "fake-codex")
    launch_marker = Path.join(test_root, "codex-started")
    repository = Path.expand("../../..", __DIR__)
    ponytail_path = Path.join([repository, ".agents", "skills", "ponytail"])

    try do
      File.mkdir_p!(test_root)
      File.write!(codex_binary, "#!/bin/sh\nprintf started > #{launch_marker}\n")
      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(test_root, "workspaces"),
        hook_after_create: "mkdir -p .agents/skills && cp -R '#{ponytail_path}' .agents/skills/ponytail",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "GH-2-missing-tdd-skill",
        title: "Require autonomous TDD before Build",
        state: "Ready",
        labels: ["backend"]
      }

      assert_raise RuntimeError, ~r/required_skill_unavailable.*tdd-autonomous/, fn ->
        AgentRunner.run(issue, nil, phase: :build, branch: "symphony/gh-2-missing-tdd-skill")
      end

      refute File.exists?(launch_marker)
    after
      File.rm_rf(test_root)
    end
  end
end
