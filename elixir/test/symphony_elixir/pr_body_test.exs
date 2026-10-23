defmodule SymphonyElixir.PRBodyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PRBody

  @body """
  Fixes #42

  #### Context

  Adds the requested behavior.

  #### TL;DR

  Adds the behavior.

  #### Summary

  - Adds the behavior.

  #### Alternatives

  - Keeps the existing implementation pattern.

  #### Test Plan

  - [x] `mix test`
  """

  test "validates a complete body and requires the exact issue reference" do
    assert :ok = PRBody.validate_agent_body(@body, "octo/app#42")
    assert {:error, :invalid_github_pull_request_body} = PRBody.validate_agent_body(@body, "octo/app#43")
  end

  test "host wraps the agent-authored body and the PR linter accepts that wrapper" do
    template = File.read!("../.github/pull_request_template.md")
    wrapped = PRBody.delivery_block(@body)

    assert wrapped =~ "<!-- symphony:delivery:start -->"
    assert wrapped =~ "<!-- symphony:delivery:end -->"
    assert PRBody.lint(template, wrapped) == []
  end

  test "agent body cannot supply Symphony's owned markers or leave template comments" do
    assert {:error, :invalid_github_pull_request_body} =
             PRBody.validate_agent_body("<!-- symphony:delivery:start -->\n" <> @body, "octo/app#42")

    assert {:error, :invalid_github_pull_request_body} =
             PRBody.validate_agent_body(String.replace(@body, "Adds the behavior.", "<!-- unfinished -->"), "octo/app#42")
  end

  test "rejects invalid inputs and issue identifiers" do
    assert {:error, :invalid_github_pull_request_body} = PRBody.validate_agent_body(nil, "octo/app#42")
    assert {:error, :invalid_github_pull_request_body} = PRBody.validate_agent_body(@body, "octo/app")
    assert ["PR template and body must be Markdown strings."] == PRBody.lint(nil, @body)
  end

  test "rejects out-of-order Symphony delivery markers" do
    template = File.read!("../.github/pull_request_template.md")
    body = @body <> "\n<!-- symphony:delivery:end -->\n<!-- symphony:delivery:start -->"

    assert ["Symphony delivery markers are out of order."] == PRBody.lint(template, body)

    assert ["PR body must contain one matching pair of Symphony delivery markers."] ==
             PRBody.lint(template, @body <> "\n<!-- symphony:delivery:end -->")
  end
end
