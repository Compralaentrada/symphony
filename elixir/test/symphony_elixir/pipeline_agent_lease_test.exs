defmodule SymphonyElixir.PipelineAgentLeaseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pipeline.Store

  test "the test runtime stores pipeline state in a temporary database" do
    assert path = Store.database_path()
    assert String.starts_with?(path, System.tmp_dir!())
  end

  test "a superseded attempt cannot keep the GitHub write lease" do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-agent-lease-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    task = %{
      "issue_id" => "octo/app#42",
      "generation" => 1,
      "phase" => "build",
      "attempts" => %{"build" => 2}
    }

    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(task["issue_id"], 1, "build", 1)
    assert :ok = Store.begin_phase(task["issue_id"], 1, "build", 2)

    refute Store.agent_lease_active?(task["issue_id"], 1, "build", 1)
    assert Store.agent_lease_active?(task["issue_id"], 1, "build", 2)
  end

  test "individual and pre-restart pipeline sessions lose their write lease" do
    previous_path = Application.fetch_env(:symphony_elixir, :pipeline_database_path)
    root = Path.join(System.tmp_dir!(), "symphony-agent-lease-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(root, "pipeline.sqlite3"))

    on_exit(fn ->
      case previous_path do
        {:ok, path} -> Application.put_env(:symphony_elixir, :pipeline_database_path, path)
        :error -> Application.delete_env(:symphony_elixir, :pipeline_database_path)
      end

      File.rm_rf!(root)
    end)

    issue_id = "octo/app#42"
    token = "session-one"

    assert :ok = Store.begin_agent_lease(issue_id, token)
    assert Store.agent_lease_active?(issue_id, token)
    assert :ok = Store.begin_agent_lease(issue_id, "session-two")
    refute Store.agent_lease_active?(issue_id, token)
    assert Store.agent_lease_active?(issue_id, "session-two")

    task = %{"issue_id" => issue_id, "generation" => 2, "phase" => "review", "attempts" => %{"review" => 1}}
    assert :ok = Store.save_task(task)
    assert :ok = Store.begin_phase(issue_id, 2, "review", 1)
    assert Store.agent_lease_active?(issue_id, 2, "review", 1)
    assert :ok = Store.interrupt_running_phases()
    refute Store.agent_lease_active?(issue_id, 2, "review", 1)
  end
end
