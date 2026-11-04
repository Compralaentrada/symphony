defmodule SymphonyElixir.PilotDocumentationTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @runbook Path.join(@repo_root, "docs/superboard-pilot-runbook.md")
  @evidence_template Path.join(@repo_root, "docs/superboard-pilot-evidence-template.md")

  test "pilot documentation links point to existing local files" do
    for markdown_path <- [@runbook, @evidence_template] do
      markdown = File.read!(markdown_path)

      Regex.scan(~r/\[[^\]]+\]\(([^)]+)\)/, markdown, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&String.starts_with?(&1, ["http://", "https://", "mailto:"]))
      |> Enum.each(fn target ->
        [relative_path | _fragment] = String.split(target, "#", parts: 2)
        linked_path = Path.expand(relative_path, Path.dirname(markdown_path))

        assert File.exists?(linked_path), "broken local link #{target} in #{markdown_path}"
      end)
    end
  end

  test "pilot matrix covers every required scenario" do
    runbook = File.read!(@runbook)

    for scenario <- [
          "BUG",
          "FEATURE",
          "QA",
          "DEP-OPEN",
          "DEP-RESOLVED",
          "HUMAN-FEEDBACK",
          "RESTART-BUILD",
          "RESTART-QA",
          "RESTART-REVIEW",
          "TWO-REPOS",
          "MERGE-POLICY"
        ] do
      assert runbook =~ "| #{scenario} |", "pilot matrix is missing #{scenario}"
    end
  end

  test "merge policy matrix documents automatic recovery and completion" do
    runbook = File.read!(@runbook)

    for outcome <- [
          "cierra la issue y mueve el item del Project a `Done` tras verificar el merge",
          "conserva la tarea allí para una decisión humana y no asume quién movió el item",
          "Build integra la base en la rama de la tarea",
          "QA y Review se repiten sobre el SHA resultante",
          "el rollup de GitHub puede faltar y, si existe, debe ser satisfactorio"
        ] do
      assert runbook =~ outcome, "merge policy matrix is missing #{outcome}"
    end
  end

  test "documented policy and capacity options match the configuration schema" do
    runbook = File.read!(@runbook)
    evidence_template = File.read!(@evidence_template)
    schema = File.read!(Path.join(@repo_root, "elixir/lib/symphony_elixir/config/schema.ex"))

    assert runbook =~ "agent.max_concurrent_agents"
    assert schema =~ ~r/field\(:max_concurrent_agents, :integer, default: 10\)/

    assert runbook =~ "merge_policy"
    assert runbook =~ "tracker.provider.merge_policy"
    assert runbook =~ "`human`"
    assert runbook =~ "`auto`"
    assert evidence_template =~ "`human` o `auto`"
    assert schema =~ ~r/field\(:merge_policy, :string, default: "human"\)/
    assert schema =~ ~r/validate_inclusion\(:merge_policy, \["human", "auto"\]\)/
  end
end
