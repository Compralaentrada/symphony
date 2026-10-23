defmodule SymphonyElixir.PipelineStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Pipeline.Store

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-pipeline-store-#{System.unique_integer([:positive])}")
    database_path = Path.join(root, "pipeline.sqlite3")
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    Application.put_env(:symphony_elixir, :pipeline_database_path, database_path)

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  test "returns the latest phase result for only the requested generation" do
    issue_id = "octo/app#1"
    earlier = %{"outcome" => "passed", "summary" => "Earlier attempt"}
    latest = %{"outcome" => "passed", "summary" => "Latest attempt"}
    next_generation = %{"outcome" => "ready", "summary" => "New generation"}

    commit_phase(issue_id, 1, "build", 1, earlier)
    commit_phase(issue_id, 1, "qa", 1, earlier)
    commit_phase(issue_id, 1, "build", 2, latest)
    commit_phase(issue_id, 2, "build", 1, next_generation)

    assert {:ok, %{phase: "build", result: ^latest, updated_at: updated_at}} =
             Store.latest_phase_result(issue_id, 1)

    assert {:ok, _datetime, 0} = DateTime.from_iso8601(updated_at)

    assert {:ok, %{phase: "build", result: ^next_generation}} =
             Store.latest_phase_result(issue_id, 2)
  end

  test "returns explicit absence when the generation has no phase results" do
    assert {:ok, nil} = Store.latest_phase_result("octo/app#2", 1)
  end

  defp commit_phase(issue_id, generation, phase, attempt, result) do
    task = %{"issue_id" => issue_id, "generation" => generation}
    assert :ok = Store.commit_phase(task, phase, attempt, result, [])
  end
end
