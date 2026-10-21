defmodule Mix.Tasks.Title.CheckTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Title.Check

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("title.check")
    :ok
  end

  test "prints help" do
    output = capture_io(fn -> assert :ok = Check.run(["--help"]) end)
    assert output =~ "mix title.check --title"
  end

  test "rejects invalid options and unexpected arguments" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Check.run(["--wat"])
    end

    assert_raise Mix.Error, ~r/Unexpected argument/, fn ->
      Check.run(["extra", "--title", "feat(projects): usar estados canónicos"])
    end
  end

  test "accepts a scoped Conventional Commit title" do
    output =
      capture_io(fn ->
        assert :ok = Check.run(["--title", "feat(projects): usar estados canónicos"])
      end)

    assert output =~ "Title format OK"
  end

  test "accepts the security type and breaking change marker" do
    output =
      capture_io(fn ->
        assert :ok = Check.run(["--title", "security(deps)!: actualizar dependencias"])
      end)

    assert output =~ "Title format OK"
  end

  test "rejects titles without an allowed type and required scope" do
    error_output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/Conventional Commit title invalid/, fn ->
          Check.run(["--title", "feature: add projects support"])
        end
      end)

    assert error_output =~ "Expected `type(scope): description`"
  end

  test "rejects uppercase scopes, trailing periods, and titles over 72 characters" do
    for title <- [
          "feat(GitHub): add projects support",
          "feat(projects): add projects support.",
          "feat(projects): " <> String.duplicate("a", 57)
        ] do
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/Conventional Commit title invalid/, fn ->
          Check.run(["--title", title])
        end
      end)
    end
  end

  test "rejects leading or trailing whitespace" do
    for title <- [
          " feat(projects): usar estados canónicos",
          "feat(projects): usar estados canónicos "
        ] do
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/Conventional Commit title invalid/, fn ->
          Check.run(["--title", title])
        end
      end)
    end
  end

  test "requires a title" do
    assert_raise Mix.Error, ~r/Missing required option --title/, fn ->
      Check.run([])
    end
  end
end
