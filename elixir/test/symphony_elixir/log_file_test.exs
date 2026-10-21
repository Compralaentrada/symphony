defmodule SymphonyElixir.LogFileTest do
  use ExUnit.Case, async: false

  require Logger

  alias SymphonyElixir.LogFile

  @main_handler_id :symphony_disk_log
  @error_handler_id :symphony_error_disk_log

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/symphony.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/symphony-logs") == "/tmp/symphony-logs/log/symphony.log"
  end

  test "duplicates warning and error events into a dedicated log" do
    previous_log_file = Application.fetch_env(:symphony_elixir, :log_file)
    logs_root = Path.join(System.tmp_dir!(), "symphony-log-file-test-#{System.unique_integer([:positive])}")
    log_file = Path.join(logs_root, "log/symphony.log.1")
    error_log_file = Path.join(logs_root, "log/symphony-errors.log.1")
    marker = "log-handler-integration-#{System.unique_integer([:positive])}"

    Application.put_env(:symphony_elixir, :log_file, Path.rootname(log_file, ".1"))
    assert :ok = LogFile.configure()

    on_exit(fn ->
      :logger.remove_handler(@error_handler_id)
      :logger.remove_handler(@main_handler_id)
      restore_log_file(previous_log_file)
      assert :ok = LogFile.configure()
      File.rm_rf!(logs_root)
    end)

    Logger.info("#{marker} info")
    Logger.warning("#{marker} warning")
    Logger.error("#{marker} error")

    assert :ok = :logger_disk_log_h.filesync(@main_handler_id)
    assert :ok = :logger_disk_log_h.filesync(@error_handler_id)

    main_log = File.read!(log_file)
    error_log = File.read!(error_log_file)

    assert main_log =~ "#{marker} info"
    assert main_log =~ "#{marker} warning"
    assert main_log =~ "#{marker} error"
    assert error_log =~ "#{marker} warning"
    assert error_log =~ "#{marker} error"
    refute error_log =~ "#{marker} info"
  end

  defp restore_log_file({:ok, log_file}) do
    Application.put_env(:symphony_elixir, :log_file, log_file)
  end

  defp restore_log_file(:error) do
    Application.delete_env(:symphony_elixir, :log_file)
  end
end
