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

    Enum.each(Skills.select(issue), fn skill ->
      skill_path = Path.join([workspace, ".agents", "skills", skill, "SKILL.md"])
      File.mkdir_p!(Path.dirname(skill_path))
      File.write!(skill_path, "---\nname: #{skill}\n---\n")
    end)

    assert :ok = Skills.ensure_available(workspace, issue)
  end

  test "reports a missing required skill before Codex starts" do
    workspace = Path.join(System.tmp_dir!(), "codex-skills-missing-#{System.unique_integer([:positive])}")
    issue = %Issue{labels: ["ready-for-agent"]}
    on_exit(fn -> File.rm_rf(workspace) end)

    for skill <- ["ponytail", "code-review"] do
      skill_path = Path.join([workspace, ".agents", "skills", skill, "SKILL.md"])
      File.mkdir_p!(Path.dirname(skill_path))
      File.write!(skill_path, "---\nname: #{skill}\n---\n")
    end

    expected_path = Path.join([workspace, ".agents", "skills", "tdd", "SKILL.md"])

    assert {:error, {:required_skill_unavailable, "tdd", ^expected_path}} =
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

  test "selects skills by explicit issue work labels" do
    assert Skills.select(%Issue{labels: nil}) == ["ponytail", "tdd", "code-review"]
    assert Skills.select(%Issue{labels: ["ready-for-agent"]}) == ["ponytail", "tdd", "code-review"]

    assert Skills.select(%Issue{labels: ["Frontend"]}) == [
             "ponytail",
             "tdd",
             "code-review",
             "impeccable"
           ]

    assert Skills.select(%Issue{labels: ["docs"]}) == [
             "ponytail",
             "tdd",
             "code-review"
           ]

    assert Skills.select(%Issue{labels: ["user-facing"]}) == [
             "ponytail",
             "tdd",
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

    assert Skills.select(backend_issue, :build) == ["ponytail"]
    assert Skills.select(backend_issue, :qa) == []
    assert Skills.select(backend_issue, :review) == []
    assert Skills.select(backend_issue, :diagnostic) == []
    assert Skills.select(backend_issue, :unknown_phase) == []

    frontend_copy_issue = %Issue{labels: ["frontend", "customer-facing"]}

    assert Skills.select(frontend_copy_issue, :build) == ["ponytail", "humanizer"]
    assert Skills.select(frontend_copy_issue, :qa) == ["humanizer"]
    assert Skills.select(frontend_copy_issue, :review) == ["humanizer"]
  end
end
