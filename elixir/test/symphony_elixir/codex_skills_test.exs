defmodule SymphonyElixir.Codex.SkillsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Skills
  alias SymphonyElixir.Tracker.Issue

  test "all pinned skills are available in the versioned project" do
    workspace = Path.expand("../../..", __DIR__)
    issue = %Issue{labels: ["frontend", "docs"]}

    assert :ok = Skills.ensure_available(workspace, issue)
  end

  test "verifies only selected skills are available in the workspace" do
    workspace = Path.join(System.tmp_dir!(), "codex-skills-#{System.unique_integer([:positive])}")
    issue = %Issue{labels: ["ready-for-agent"]}
    on_exit(fn -> File.rm_rf(workspace) end)

    copy_skills(workspace, Skills.select(issue))

    assert :ok = Skills.ensure_available(workspace, issue)
  end

  test "preflights autonomous TDD for Build in a prepared workspace" do
    workspace = Path.join(System.tmp_dir!(), "codex-build-skills-#{System.unique_integer([:positive])}")
    issue = %Issue{labels: ["backend"]}
    on_exit(fn -> File.rm_rf(workspace) end)

    copy_skills(workspace, Skills.select(issue, :build))

    assert :ok = Skills.ensure_available(workspace, issue, :build)
  end

  test "autonomous TDD chooses and records public interfaces without human approval" do
    repository = Path.expand("../../..", __DIR__)
    skill_path = Path.join([repository, ".agents", "skills", "tdd-autonomous", "SKILL.md"])
    skill = File.read!(skill_path)

    assert skill =~ "public interface"
    assert skill =~ "Record those interfaces"
    assert skill =~ "do not ask for human approval"
    assert skill =~ "fails because the behavior is not implemented"
    assert skill =~ "confirm it passes"
  end

  test "reports a missing required skill before Codex starts" do
    workspace = Path.join(System.tmp_dir!(), "codex-skills-missing-#{System.unique_integer([:positive])}")
    issue = %Issue{labels: ["ready-for-agent", "customer-facing"]}
    on_exit(fn -> File.rm_rf(workspace) end)

    copy_skills(workspace, ["ponytail", "code-review"])

    expected_path = Path.join([workspace, ".agents", "skills", "humanizer", "SKILL.md"])

    assert {:error, {:required_skill_unavailable, "humanizer", ^expected_path}} =
             Skills.ensure_available(workspace, issue)
  end

  test "reports an unavailable workspace path" do
    parent = Path.join(System.tmp_dir!(), "codex-skills-file-#{System.unique_integer([:positive])}")
    workspace = Path.join(parent, "workspace")
    on_exit(fn -> File.rm(parent) end)

    File.write!(parent, "not a directory")

    assert {:error, {:skill_workspace_unavailable, ^workspace, _reason}} =
             Skills.ensure_available(workspace, %Issue{labels: []})
  end

  test "reports an unreadable skill path as unavailable" do
    workspace = Path.join(System.tmp_dir!(), "codex-skills-file-component-#{System.unique_integer([:positive])}")
    skills_path = Path.join([workspace, ".agents", "skills"])
    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.dirname(skills_path))
    File.write!(skills_path, "not a directory")
    skill_path = Path.join([skills_path, "ponytail", "SKILL.md"])

    assert {:error, {:required_skill_unavailable, "ponytail", ^skill_path}} =
             Skills.ensure_available(workspace, %Issue{labels: []})
  end

  test "does not accept a skill file that escapes the workspace through a symlink" do
    test_root = Path.join(System.tmp_dir!(), "codex-skills-symlink-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    outside_skill = Path.join(test_root, "SKILL.md")
    issue = %Issue{labels: ["ready-for-agent"]}
    skill_path = Path.join([workspace, ".agents", "skills", "ponytail", "SKILL.md"])
    on_exit(fn -> File.rm_rf(test_root) end)

    File.mkdir_p!(Path.dirname(skill_path))
    File.write!(outside_skill, "---\nname: ponytail\n---\n")
    File.ln_s!(outside_skill, skill_path)

    assert {:error, {:required_skill_unavailable, "ponytail", ^skill_path}} =
             Skills.ensure_available(workspace, issue)
  end

  test "reports a skill path with a symlink loop as unavailable" do
    workspace = Path.join(System.tmp_dir!(), "codex-skills-loop-#{System.unique_integer([:positive])}")
    ponytail_dir = Path.join([workspace, ".agents", "skills", "ponytail"])
    skill_path = Path.join([ponytail_dir, "SKILL.md"])
    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.dirname(ponytail_dir))
    File.ln_s!("ponytail", ponytail_dir)

    assert {:error, {:required_skill_unavailable, "ponytail", ^skill_path}} =
             Skills.ensure_available(workspace, %Issue{labels: []})
  end

  test "rejects a changed skill file and a changed pinned fingerprint" do
    workspace = Path.join(System.tmp_dir!(), "codex-skills-changed-#{System.unique_integer([:positive])}")
    skill_dir = Path.join([workspace, ".agents", "skills", "ponytail"])
    on_exit(fn -> File.rm_rf(workspace) end)

    copy_skills(workspace, ["ponytail", "tdd-autonomous"])
    skill_path = Path.join(skill_dir, "SKILL.md")
    File.write!(skill_path, File.read!(skill_path) <> "\nchanged\n")

    assert {:error, {:skill_snapshot_unavailable, 23, output}} =
             Skills.ensure_available(workspace, %Issue{labels: []}, :build)

    assert output =~ "Skill file checksum mismatch"

    copy_skills(workspace, ["ponytail", "tdd-autonomous"])
    checksum_path = Path.join(skill_dir, "CHECKSUMS.sha256")
    File.write!(checksum_path, File.read!(checksum_path) <> "\n")

    assert {:error, {:skill_snapshot_unavailable, 21, output}} =
             Skills.ensure_available(workspace, %Issue{labels: []}, :build)

    assert output =~ "Skill fingerprint mismatch: ponytail"
  end

  test "snapshots selected skill versions and fingerprints by phase" do
    issue = %Issue{labels: ["customer-facing"]}
    config = Skills.effective_config(issue)

    assert [
             %{"name" => "ponytail", "version" => "v5.3.2", "fingerprint" => fingerprint},
             %{"name" => "tdd-autonomous", "version" => "v1.0.0", "fingerprint" => tdd_fingerprint},
             %{"name" => "humanizer", "version" => "v3.1.0"}
           ] = config["skills"]["build"]

    assert fingerprint == "c45df1e5846a557d1d4e1ccf103d5f7ef301de1e7d75d4d66b39aebd47a4497a"
    assert tdd_fingerprint == "35f53a76898dc0bc6507f58f70611f14caf842da1be7bfae389c4fbe275c5b15"
    assert [%{"name" => "humanizer", "version" => "v3.1.0"}] = config["skills"]["qa"]
    assert Skills.attempt_snapshot(issue, %{"effective_config" => config}, :build) == config["skills"]["build"]
    assert Skills.attempt_snapshot(issue, nil, nil) == Skills.snapshot_for_phase(issue, nil)
    assert Skills.select(issue, nil) == Skills.select(issue)
    assert Skills.snapshot_for_phase(issue, :unknown) == []
    assert Skills.snapshot_for_phase(issue, "unknown") == []
  end

  test "rejects malformed and unpinned skill snapshots" do
    workspace = Path.expand("../../..", __DIR__)

    assert {:error, {:invalid_skill_snapshot, %{"version" => "v1"}}} =
             Skills.verify_snapshot(workspace, [%{"version" => "v1"}])

    assert {:error, {:invalid_skill_snapshot, "unlisted"}} =
             Skills.verify_snapshot(workspace, [%{"name" => "unlisted"}])
  end

  test "selects skills by explicit issue work labels" do
    assert Skills.select(%Issue{labels: nil}) == ["ponytail", "code-review"]
    assert Skills.select(%Issue{labels: ["ready-for-agent"]}) == ["ponytail", "code-review"]

    assert Skills.select(%Issue{labels: ["Frontend"]}) == [
             "ponytail",
             "code-review"
           ]

    assert Skills.select(%Issue{labels: ["docs"]}) == ["ponytail", "code-review"]

    assert Skills.select(%Issue{labels: ["user-facing"]}) == [
             "ponytail",
             "code-review",
             "humanizer"
           ]

    assert Skills.select(%Issue{labels: ["writing-only"]}) == ["code-review"]

    assert Skills.select(%Issue{labels: ["writing-only", "user-facing"]}) == [
             "code-review",
             "humanizer"
           ]
  end

  test "selects pipeline skills by fixed phase and applicable task labels" do
    backend_issue = %Issue{labels: ["backend"]}

    assert Skills.select(backend_issue, :build) == ["ponytail", "tdd-autonomous"]
    assert Skills.select(backend_issue, :qa) == []
    assert Skills.select(backend_issue, :review) == []
    assert Skills.select(backend_issue, :diagnostic) == []
    assert Skills.select(backend_issue, :unknown_phase) == []

    frontend_copy_issue = %Issue{labels: ["frontend", "customer-facing"]}

    assert Skills.select(frontend_copy_issue, :build) == ["ponytail", "tdd-autonomous", "humanizer"]
    assert Skills.select(frontend_copy_issue, :qa) == ["humanizer"]
    assert Skills.select(frontend_copy_issue, :review) == ["humanizer"]
  end

  test "selects autonomous TDD for code, docs, and mixed Build tasks, but not text-only tasks" do
    assert Skills.select(%Issue{labels: ["backend"]}, :build) == ["ponytail", "tdd-autonomous"]
    assert Skills.select(%Issue{labels: ["writing-only"]}, :build) == []
    assert Skills.select(%Issue{labels: ["text-only"]}, :build) == []
    assert Skills.select(%Issue{labels: ["docs"]}, :build) == ["ponytail", "tdd-autonomous"]

    assert Skills.select(%Issue{labels: ["backend", "docs"]}, :build) == [
             "ponytail",
             "tdd-autonomous"
           ]

    assert Skills.select(%Issue{labels: ["writing-only", "user-facing"]}, :build) == ["humanizer"]
    assert Skills.select(%Issue{labels: ["backend"]}, :qa) == []
    assert Skills.select(%Issue{labels: ["backend"]}, :review) == []
  end

  defp copy_skills(workspace, skills) do
    repository = Path.expand("../../..", __DIR__)

    Enum.each(skills, fn skill ->
      source = Path.join([repository, ".agents", "skills", skill])
      destination = Path.join([workspace, ".agents", "skills", skill])
      File.mkdir_p!(Path.dirname(destination))
      File.rm_rf!(destination)
      File.cp_r!(source, destination)
    end)
  end
end
