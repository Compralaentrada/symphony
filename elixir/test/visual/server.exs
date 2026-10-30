defmodule VisualPreviewOrchestrator do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def init(:ok), do: {:ok, :ok}

  def handle_call(:snapshot, _from, state) do
    now = DateTime.utc_now()

    snapshot = %{
      running: [
        %{
          issue_id: "preview-1",
          identifier: "DEMO-101",
          issue_url: nil,
          state: "Building",
          session_id: "preview-session",
          turn_count: 2,
          codex_app_server_pid: nil,
          last_codex_message: "Running checks",
          last_codex_timestamp: now,
          last_codex_event: :notification,
          codex_input_tokens: 1200,
          codex_output_tokens: 800,
          codex_total_tokens: 2000,
          started_at: now
        }
      ],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 1200, output_tokens: 800, total_tokens: 2000, seconds_running: 42.5},
      rate_limits: nil
    }

    {:reply, snapshot, state}
  end
end

preview_root = Path.join(System.tmp_dir!(), "symphony-visual-#{System.pid()}")
Application.put_env(:symphony_elixir, :pipeline_database_path, Path.join(preview_root, "pipeline.sqlite3"))
Application.put_env(:symphony_elixir, :log_file, Path.join(preview_root, "symphony.log"))
SymphonyElixir.Workflow.set_workflow_file_path(Path.expand("test/fixtures/startup_workflow.md"))
{:ok, _} = Application.ensure_all_started(:symphony_elixir)
{:ok, _} = VisualPreviewOrchestrator.start_link([])
{:ok, _} = SymphonyElixir.HttpServer.start_link(port: 4987, host: "127.0.0.1", orchestrator: VisualPreviewOrchestrator)
IO.puts("Visual preview: http://127.0.0.1:4987/")
Process.sleep(:infinity)
