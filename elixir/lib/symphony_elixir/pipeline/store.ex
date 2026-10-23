defmodule SymphonyElixir.Pipeline.Store do
  @moduledoc false

  alias Exqlite.Basic

  @spec database_path() :: Path.t()
  def database_path do
    Application.get_env(:symphony_elixir, :pipeline_database_path) ||
      Path.join(System.user_home!(), ".symphony/pipeline.sqlite3")
  end

  @spec get_task(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get_task(issue_id) do
    with_db(fn conn ->
      case query(conn, "SELECT payload FROM pipeline_tasks WHERE issue_id = ?", [issue_id]) do
        {:ok, [[payload]]} -> {:ok, Jason.decode!(payload)}
        {:ok, []} -> {:ok, nil}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec tasks() :: {:ok, [map()]} | {:error, term()}
  def tasks do
    with_db(fn conn ->
      with {:ok, rows} <- query(conn, "SELECT payload FROM pipeline_tasks ORDER BY issue_id") do
        {:ok, Enum.map(rows, fn [payload] -> Jason.decode!(payload) end)}
      end
    end)
  end

  @spec latest_phase_result(String.t(), pos_integer()) ::
          {:ok, %{phase: String.t(), result: map(), updated_at: String.t()} | nil} | {:error, term()}
  def latest_phase_result(issue_id, generation) do
    with_db(fn conn ->
      case query(
             conn,
             "SELECT phase, result, updated_at FROM pipeline_phases WHERE issue_id = ? AND generation = ? ORDER BY updated_at DESC, rowid DESC LIMIT 1",
             [issue_id, generation]
           ) do
        {:ok, [[phase, result, updated_at]]} ->
          {:ok, %{phase: phase, result: Jason.decode!(result), updated_at: updated_at}}

        {:ok, []} ->
          {:ok, nil}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  @spec save_task(map()) :: :ok | {:error, term()}
  def save_task(task), do: with_db(&save_task(&1, task))

  @spec begin_agent_lease(String.t(), String.t()) :: :ok | {:error, term()}
  def begin_agent_lease(issue_id, token) do
    with_db(fn conn ->
      execute(
        conn,
        "INSERT INTO agent_leases (issue_id, token, status) VALUES (?, ?, 'active') ON CONFLICT(issue_id) DO UPDATE SET token = excluded.token, status = 'active'",
        [issue_id, token]
      )
    end)
  end

  @spec end_agent_lease(String.t(), String.t()) :: :ok | {:error, term()}
  def end_agent_lease(issue_id, token) do
    with_db(fn conn ->
      execute(conn, "UPDATE agent_leases SET status = 'ended' WHERE issue_id = ? AND token = ?", [issue_id, token])
    end)
  end

  @spec agent_lease_active?(String.t(), String.t()) :: boolean()
  def agent_lease_active?(issue_id, token) do
    with_db(fn conn ->
      case query(conn, "SELECT status FROM agent_leases WHERE issue_id = ? AND token = ?", [issue_id, token]) do
        {:ok, [["active"]]} -> true
        _ -> false
      end
    end)
    |> case do
      true -> true
      _ -> false
    end
  end

  @spec revoke_agent_leases() :: :ok | {:error, term()}
  def revoke_agent_leases do
    with_db(&execute(&1, "UPDATE agent_leases SET status = 'revoked' WHERE status = 'active'"))
  end

  @spec interrupt_running_phases() :: :ok | {:error, term()}
  def interrupt_running_phases do
    with_db(fn conn ->
      execute(conn, "UPDATE pipeline_runs SET status = 'interrupted', ended_at = ? WHERE status = 'running'", [timestamp()])
    end)
  end

  @spec supersede_pending_operations(String.t()) :: :ok | {:error, term()}
  def supersede_pending_operations(issue_id) do
    with_db(fn conn ->
      execute(conn, "UPDATE pipeline_operations SET status = 'superseded', updated_at = ? WHERE issue_id = ? AND status = 'pending'", [timestamp(), issue_id])
    end)
  end

  @spec save_task_with_operations(map(), [map()]) :: :ok | {:error, term()}
  def save_task_with_operations(task, operations) do
    with_db(fn conn ->
      with :ok <- execute(conn, "BEGIN IMMEDIATE"),
           :ok <- save_task(conn, task),
           :ok <- insert_operations(conn, operations),
           :ok <- execute(conn, "COMMIT") do
        :ok
      else
        {:error, _reason} = error ->
          execute(conn, "ROLLBACK")
          error
      end
    end)
  end

  @spec begin_phase(String.t(), pos_integer(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def begin_phase(issue_id, generation, phase, attempt) do
    with_db(fn conn ->
      execute(
        conn,
        """
        INSERT INTO pipeline_runs (issue_id, generation, phase, attempt, status, started_at)
        VALUES (?, ?, ?, ?, 'running', ?)
        ON CONFLICT(issue_id, generation, phase, attempt)
        DO UPDATE SET status = 'running', started_at = excluded.started_at, ended_at = NULL
        """,
        [issue_id, generation, phase, attempt, timestamp()]
      )
    end)
  end

  @spec commit_phase(map(), String.t(), non_neg_integer(), map(), [map()]) :: :ok | {:error, term()}
  def commit_phase(task, phase, attempt, result, operations) do
    with_db(fn conn ->
      with :ok <- execute(conn, "BEGIN IMMEDIATE"),
           :ok <- save_task(conn, task),
           :ok <- save_run(conn, task, phase, attempt, "complete", result),
           :ok <- save_phase(conn, task, phase, attempt, result),
           :ok <- save_checkpoint(conn, task, phase, result),
           :ok <- insert_operations(conn, operations),
           :ok <- execute(conn, "COMMIT") do
        :ok
      else
        {:error, _reason} = error ->
          execute(conn, "ROLLBACK")
          error
      end
    end)
  end

  @spec interrupt_phase(String.t(), pos_integer(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def interrupt_phase(issue_id, generation, phase, attempt) do
    with_db(fn conn ->
      execute(
        conn,
        "UPDATE pipeline_runs SET status = 'interrupted', ended_at = ? WHERE issue_id = ? AND generation = ? AND phase = ? AND attempt = ? AND status = 'running'",
        [timestamp(), issue_id, generation, phase, attempt]
      )
    end)
  end

  @spec agent_lease_active?(String.t(), pos_integer(), String.t(), pos_integer()) :: boolean()
  def agent_lease_active?(issue_id, generation, phase, attempt) do
    with_db(fn conn ->
      case query(
             conn,
             "SELECT t.payload, r.status FROM pipeline_tasks t JOIN pipeline_runs r ON r.issue_id = t.issue_id WHERE t.issue_id = ? AND r.generation = ? AND r.phase = ? AND r.attempt = ?",
             [issue_id, generation, phase, attempt]
           ) do
        {:ok, rows} -> Enum.any?(rows, &active_pipeline_lease_row?(&1, generation, phase, attempt))
        _ -> false
      end
    end)
    |> case do
      true -> true
      _ -> false
    end
  end

  defp active_pipeline_lease_row?([payload, status], generation, phase, attempt) do
    task = Jason.decode!(payload)

    status == "running" and task["generation"] == generation and task["phase"] == phase and
      get_in(task, ["attempts", phase]) == attempt
  end

  @spec pending_operations(String.t()) :: {:ok, [map()]} | {:error, term()}
  def pending_operations(issue_id) do
    with_db(fn conn ->
      with {:ok, rows} <-
             query(
               conn,
               "SELECT operation_key, kind, payload FROM pipeline_operations WHERE issue_id = ? AND status = 'pending' ORDER BY rowid",
               [issue_id]
             ) do
        {:ok,
         Enum.map(rows, fn [key, kind, payload] ->
           %{key: key, kind: kind, payload: Jason.decode!(payload)}
         end)}
      end
    end)
  end

  @spec complete_operation(String.t(), term()) :: :ok | {:error, term()}
  def complete_operation(key, result) do
    with_db(fn conn ->
      execute(
        conn,
        "UPDATE pipeline_operations SET status = 'complete', result = ?, updated_at = ? WHERE operation_key = ?",
        [Jason.encode!(result), timestamp(), key]
      )
    end)
  end

  defp save_task(conn, task) do
    execute(
      conn,
      "INSERT INTO pipeline_tasks (issue_id, payload, updated_at) VALUES (?, ?, ?) ON CONFLICT(issue_id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at",
      [task["issue_id"], Jason.encode!(task), timestamp()]
    )
  end

  defp save_run(conn, task, phase, attempt, status, result) do
    execute(
      conn,
      "UPDATE pipeline_runs SET status = ?, ended_at = ?, result = ? WHERE issue_id = ? AND generation = ? AND phase = ? AND attempt = ?",
      [status, timestamp(), Jason.encode!(result), task["issue_id"], task["generation"], phase, attempt]
    )
  end

  defp save_phase(conn, task, phase, attempt, result) do
    sha = result["sha"] || task["current_sha"]

    execute(
      conn,
      "INSERT INTO pipeline_phases (issue_id, generation, phase, attempt, status, sha, result, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(issue_id, generation, phase, attempt) DO UPDATE SET status = excluded.status, sha = excluded.sha, result = excluded.result, updated_at = excluded.updated_at",
      [task["issue_id"], task["generation"], phase, attempt, result["outcome"], sha, Jason.encode!(result), timestamp()]
    )
  end

  defp save_checkpoint(conn, task, phase, result) do
    sha = result["sha"] || task["current_sha"]

    if is_binary(sha) do
      execute(
        conn,
        "INSERT INTO pipeline_checkpoints (issue_id, generation, phase, sha, evidence, created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(issue_id, generation, phase, sha) DO UPDATE SET evidence = excluded.evidence",
        [task["issue_id"], task["generation"], phase, sha, Jason.encode!(result), timestamp()]
      )
    else
      :ok
    end
  end

  defp insert_operations(conn, operations) do
    Enum.reduce_while(operations, :ok, fn operation, :ok ->
      case execute(
             conn,
             "INSERT INTO pipeline_operations (operation_key, issue_id, kind, payload, status, created_at, updated_at) VALUES (?, ?, ?, ?, 'pending', ?, ?) ON CONFLICT(operation_key) DO NOTHING",
             [operation.key, operation.issue_id, operation.kind, Jason.encode!(operation.payload), timestamp(), timestamp()]
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp with_db(fun) do
    path = database_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, conn} <- Basic.open(path),
         :ok <- initialize(conn) do
      try do
        fun.(conn)
      after
        Basic.close(conn)
      end
    else
      {:error, reason} -> {:error, {:pipeline_database, reason}}
    end
  rescue
    error in [Jason.EncodeError, File.Error] -> {:error, {:pipeline_database, error}}
  end

  defp initialize(conn) do
    with :ok <- execute(conn, "PRAGMA journal_mode = WAL"),
         :ok <- execute(conn, "PRAGMA synchronous = FULL"),
         :ok <- execute(conn, "PRAGMA busy_timeout = 5000"),
         :ok <- execute(conn, "CREATE TABLE IF NOT EXISTS pipeline_tasks (issue_id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at TEXT NOT NULL)"),
         :ok <-
           execute(
             conn,
             "CREATE TABLE IF NOT EXISTS pipeline_runs (issue_id TEXT NOT NULL, generation INTEGER NOT NULL, phase TEXT NOT NULL, attempt INTEGER NOT NULL, status TEXT NOT NULL, started_at TEXT NOT NULL, ended_at TEXT, result TEXT, PRIMARY KEY (issue_id, generation, phase, attempt))"
           ),
         :ok <-
           execute(
             conn,
             "CREATE TABLE IF NOT EXISTS pipeline_phases (issue_id TEXT NOT NULL, generation INTEGER NOT NULL, phase TEXT NOT NULL, attempt INTEGER NOT NULL, status TEXT NOT NULL, sha TEXT, result TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (issue_id, generation, phase, attempt))"
           ),
         :ok <-
           execute(
             conn,
             "CREATE TABLE IF NOT EXISTS pipeline_checkpoints (issue_id TEXT NOT NULL, generation INTEGER NOT NULL, phase TEXT NOT NULL, sha TEXT NOT NULL, evidence TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (issue_id, generation, phase, sha))"
           ),
         :ok <-
           execute(
             conn,
             "CREATE TABLE IF NOT EXISTS pipeline_operations (operation_key TEXT PRIMARY KEY, issue_id TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, result TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)"
           ),
         :ok <-
           execute(
             conn,
             "CREATE TABLE IF NOT EXISTS agent_leases (issue_id TEXT PRIMARY KEY, token TEXT NOT NULL, status TEXT NOT NULL)"
           ) do
      execute(conn, "CREATE INDEX IF NOT EXISTS pipeline_operations_pending ON pipeline_operations (issue_id, status)")
    end
  end

  defp execute(conn, sql, params \\ []) do
    case Basic.exec(conn, sql, params) do
      {:ok, _query, _result, _conn} -> :ok
      {:error, error, _conn} -> {:error, error}
    end
  end

  defp query(conn, sql, params \\ []) do
    case Basic.exec(conn, sql, params) do
      {:ok, _query, _result, _conn} = result ->
        case Basic.rows(result) do
          {:ok, rows, _columns} -> {:ok, rows}
          {:error, reason} -> {:error, reason}
        end

      {:error, error, _conn} ->
        {:error, error}
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
