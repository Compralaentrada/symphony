defmodule SymphonyElixir.DependencySecurityTest do
  use ExUnit.Case, async: true

  test "resolved Ecto version includes the query cache growth fix" do
    ecto_version = :ecto |> Application.spec(:vsn) |> to_string()

    assert Version.compare(ecto_version, "3.14.3") in [:eq, :gt]
  end
end
