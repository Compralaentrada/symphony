defmodule SymphonyElixir.Pipeline do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Codex.Skills
  alias SymphonyElixir.{Config, Pipeline.Findings, Pipeline.Store, PRBody, Tracker}
  alias SymphonyElixir.Tracker.Issue

  @phases ~w(build qa review finalize)
  # shortcut: 30 randomized Tongue samples smooth locale scores; revisit if locale coverage or accuracy needs change.
  @report_locale_samples 30
  @report_locale_confidence 0.75
  @statuses %{
    backlog: "Backlog",
    ready: "Ready",
    building: "Building",
    qa: "QA",
    review: "Review",
    human_review: "Human Review",
    blocked: "Blocked",
    dropped: "Dropped",
    done: "Done"
  }

  @spec enabled?() :: boolean()
  def enabled? do
    tracker = Config.settings!().tracker
    tracker.kind == "github_projects"
  end

  @spec report_locale(Issue.t()) :: :en | :es
  def report_locale(%Issue{description: description}) do
    description = if is_binary(description), do: String.downcase(description), else: ""
    confidence = Enum.reduce(1..@report_locale_samples, 0.0, fn _, total -> total + Keyword.get(Tongue.detect(description), :es, 0.0) end) / @report_locale_samples
    if confidence >= @report_locale_confidence, do: :es, else: :en
  end

  @spec delivery_tasks() :: {:ok, [map()]} | {:error, term()}
  def delivery_tasks do
    with {:ok, tasks} <- Store.tasks(),
         {:ok, phase_results} <- latest_phase_results(tasks) do
      issue_ids = Enum.map(tasks, & &1["issue_id"])

      tracker_issues =
        if issue_ids == [], do: {:ok, []}, else: Tracker.fetch_issues_by_ids(issue_ids)

      {:ok, project_delivery_tasks(tasks, tracker_issues, phase_results)}
    end
  end

  @spec reconcile([String.t()]) :: :ok | {:error, term()}
  def reconcile(running_issue_ids \\ []) do
    with {:ok, tasks} <- Store.tasks() do
      reconcile_tasks(tasks, running_issue_ids)
    end
  end

  @spec prepare(Issue.t()) :: {:ok, map(), String.t()} | :ignore | {:error, term()}
  def prepare(%Issue{} = issue) do
    case Store.get_task(issue.id) do
      {:ok, existing} -> prepare_from_checkpoint(issue, existing)
      {:error, _reason} = error -> error
    end
  end

  @spec begin_phase(Issue.t(), map(), String.t()) :: {:ok, map(), pos_integer()} | {:error, term()}
  def begin_phase(%Issue{} = issue, task, phase) do
    attempts = Map.update(task["attempts"] || %{}, phase, 1, &(&1 + 1))
    task = Map.put(task, "attempts", attempts)
    attempt = attempts[phase]

    with :ok <- Store.save_task(task),
         :ok <- Store.begin_phase(issue.id, task["generation"], phase, attempt) do
      {:ok, task, attempt}
    end
  end

  @spec finish_phase(Issue.t(), map(), String.t(), pos_integer(), term()) :: :ok | {:error, term()}
  def finish_phase(%Issue{} = issue, task, phase, attempt, {:system_blocker, result})
      when phase in ["build", "qa", "review"] and is_map(result) do
    case normalize_phase_result(result, phase, report_locale(issue)) do
      {:ok, %{"outcome" => "blocked"} = normalized} ->
        if Tracker.agent_owned_writes?() do
          _ = Store.interrupt_phase(issue.id, task["generation"], phase, attempt)
          {:error, :diagnostic_handoff_required}
        else
          persist_blocked_phase(issue, task, phase, attempt, normalized)
        end

      {:ok, _normalized} ->
        {:error, :invalid_system_blocker_report}

      {:error, reason} ->
        _ = Store.interrupt_phase(issue.id, task["generation"], phase, attempt)
        {:error, reason}
    end
  end

  def finish_phase(%Issue{} = issue, task, phase, attempt, result) do
    case normalize_phase_result(result, phase, report_locale(issue)) do
      {:ok, result} ->
        with :ok <- validate_remote_handoff(phase, result) do
          finish_valid_phase(issue, clear_qa_claim(task, phase), phase, attempt, result)
        end

      {:error, reason} ->
        _ = Store.interrupt_phase(issue.id, task["generation"], phase, attempt)
        {:error, reason}
    end
  end

  defp clear_qa_claim(task, "qa"), do: Map.drop(task, ["direct_qa", "qa_claim_pending", "qa_claim_reset_seen"])
  defp clear_qa_claim(task, _phase), do: task

  @spec block_phase(Issue.t(), map(), String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def block_phase(%Issue{} = issue, task, phase, attempt, reason) when is_binary(reason) do
    result = %{
      "outcome" => "blocked",
      "summary" => "An operator must resolve an intervention before this phase can continue.",
      "reason" => reason,
      "next_step" => "Resolve the blocker and move the Project item to Ready.",
      "sha" => task["current_sha"]
    }

    persist_blocked_phase(issue, task, phase, attempt, result)
  end

  defp persist_blocked_phase(issue, task, phase, attempt, result) do
    reason = result["reason"]
    next = task |> Map.put("phase", phase) |> Map.put("status", "blocked") |> Map.put("blocked_reason", reason)
    operations = report_ops(next, phase, attempt, result) ++ [status_op(next, :blocked, reason, attempt)]
    commit(issue, next, phase, attempt, result, operations)
  end

  @spec execute_pending(Issue.t()) :: :ok | {:error, term()}
  def execute_pending(%Issue{} = issue) do
    if Tracker.agent_owned_writes?() do
      :ok
    else
      case Store.pending_operations(issue.id) do
        {:ok, operations} -> Enum.reduce_while(operations, :ok, &execute_pending_operation(issue, &1, &2))
        {:error, _reason} = error -> error
      end
    end
  end

  defp prepare_from_checkpoint(issue, existing) do
    existing = if is_map(existing), do: Map.put_new(existing, "execution_identity", Issue.execution_identity(issue)), else: existing
    _ = if(Tracker.agent_owned_writes?(), do: Store.supersede_pending_operations(issue.id), else: execute_pending(issue))

    case Store.pending_operations(issue.id) do
      {:ok, []} ->
        prepare_from_checkpoint_without_pending(issue, existing)

      _ ->
        :ignore
    end
  end

  defp prepare_from_checkpoint_without_pending(issue, existing) do
    with {:ok, existing} <- align_active_checkpoint(existing, issue) do
      prepare_checked_checkpoint(issue, existing)
    end
  end

  defp prepare_checked_checkpoint(issue, existing) do
    case checkpoint_state_mismatch(existing, issue) do
      {:mismatch, reason} ->
        block_checkpoint_mismatch(existing, issue, reason)

      :ok ->
        prepare_checkpoint(issue, existing)

      {:error, _reason} = error ->
        error
    end
  end

  defp align_active_checkpoint(%{"status" => status} = task, issue)
       when status in ["building", "qa", "review", "blocked", "human_review"] do
    cond do
      issue.state == status_value(task, :qa) ->
        align_qa_state(task, issue)

      issue.state == status_value(task, :building) and status != "building" ->
        align_checkpoint(task, "building", "build")

      issue.state == status_value(task, :review) ->
        align_review_state(task, issue)

      true ->
        {:ok, task}
    end
  end

  defp align_active_checkpoint(task, _issue), do: {:ok, task}

  defp align_qa_state(%{"status" => "qa", "phase" => "qa", "qa_claim_pending" => true} = task, _issue), do: {:ok, task}
  defp align_qa_state(%{"status" => "qa", "phase" => "qa"} = task, issue), do: refresh_checkpoint_if_head_changed(task, issue, "qa")
  defp align_qa_state(task, issue), do: align_qa_checkpoint(task, issue)
  defp align_review_state(%{"status" => "review"} = task, issue), do: refresh_checkpoint_if_head_changed(task, issue, "review")
  defp align_review_state(task, issue), do: align_review_checkpoint(task, issue)

  defp align_qa_checkpoint(task, issue) do
    with {:ok, updated} <- recover_remote_delivery(task, issue, "qa") do
      updated = Map.drop(updated, ["blocked_reason", "qa_claim_pending", "qa_claim_reset_seen", "direct_qa", "stale_merge_retry"])
      save_aligned_checkpoint(task, Map.merge(updated, %{"status" => "qa", "phase" => "qa", "direct_qa" => Issue.routable?(issue, ["qa"])}))
    end
  end

  defp align_review_checkpoint(task, issue) do
    with {:ok, recovered} <- recover_remote_delivery(task, issue, "review") do
      updated = recovered |> Map.drop(["blocked_reason", "qa_claim_pending", "qa_claim_reset_seen", "direct_qa", "stale_merge_retry"]) |> Map.merge(%{"status" => "review", "phase" => "review"})
      save_aligned_checkpoint(task, updated)
    end
  end

  defp refresh_checkpoint_if_head_changed(task, issue, phase) do
    with {:ok, delivery} <- direct_qa_delivery(Tracker.pull_request(issue), task["branch"], task["base_branch"]) do
      if delivery["current_sha"] == task["current_sha"], do: {:ok, task}, else: align_checkpoint_for_phase(task, issue, phase)
    end
  end

  defp align_checkpoint_for_phase(task, issue, "qa"), do: align_qa_checkpoint(task, issue)
  defp align_checkpoint_for_phase(task, issue, "review"), do: align_review_checkpoint(task, issue)

  defp align_checkpoint(task, status, phase) do
    updated = task |> Map.drop(["blocked_reason", "qa_claim_pending", "qa_claim_reset_seen", "direct_qa", "stale_merge_retry"]) |> Map.merge(%{"status" => status, "phase" => phase})
    updated = if phase == "build", do: updated |> Map.put("current_sha", nil) |> Map.delete("host_checks"), else: updated
    save_aligned_checkpoint(task, updated)
  end

  defp recover_remote_delivery(task, issue, phase) do
    with {:ok, reports} <- Tracker.phase_reports(issue),
         {:ok, delivery} <- direct_qa_delivery(Tracker.pull_request(issue), task["branch"], task["base_branch"]) do
      history = reports
      {task, reports} = recover_remote_attempts(task, history)
      sha = if Enum.all?(history, &is_map(&1["report"])), do: accepted_remote_sha(task, issue, reports, delivery["current_sha"]), else: nil
      qa = latest_remote_report(reports, "qa")
      checks = if phase == "review" and is_map(qa) and qa["outcome"] == "passed" and qa["sha"] == sha, do: qa["checks"] || [], else: []
      findings = history |> Enum.filter(&is_map(&1["report"])) |> Enum.reduce([], fn entry, acc -> pending_findings(%{"prior_findings" => acc}, entry["report"]) end)
      {:ok, task |> Map.merge(delivery) |> Map.merge(%{"current_sha" => sha, "host_checks" => checks, "prior_findings" => findings})}
    else
      :ignore -> {:error, :remote_phase_reports_unavailable}
      {:error, _} = error -> error
    end
  end

  defp recover_remote_attempts(task, reports) do
    generation = Enum.max([task["generation"] | Enum.map(reports, & &1["generation"])])
    reports = Enum.filter(reports, &(&1["generation"] == generation))
    attempts = if task["generation"] == generation, do: task["attempts"] || %{}, else: %{}
    attempts = Enum.reduce(reports, attempts, fn report, acc -> Map.update(acc, report["phase"], report["attempt"], &max(&1, report["attempt"])) end)
    diagnostic_attempt = Map.get(attempts, "diagnostic", 0)
    attempts = Enum.reduce(~w(build qa review finalize), attempts, fn phase, acc -> Map.update(acc, phase, diagnostic_attempt, &max(&1, diagnostic_attempt)) end)
    {Map.merge(task, %{"generation" => generation, "attempts" => attempts}), reports}
  end

  defp latest_remote_report(reports, phase) do
    reports
    |> Enum.filter(&(&1["phase"] == phase))
    |> Enum.max_by(& &1["attempt"], fn -> nil end)
    |> case do
      nil -> nil
      entry -> entry["report"]
    end
  end

  defp accepted_remote_sha(task, issue, reports, sha) do
    build = latest_remote_report(reports, "build")

    valid_build = is_map(build) and build["outcome"] == "ready" and build["sha"] == sha
    valid_branch = is_map(build) and build["branch"] == task["branch"] and build["base_branch"] == task["base_branch"]

    valid_reports = Enum.all?(reports, &is_map(&1["report"]))

    if valid_reports and (Issue.routable?(issue, ["qa"]) or (valid_build and valid_branch)),
      do: sha,
      else: nil
  end

  defp save_aligned_checkpoint(task, updated) do
    case Store.replace_task_if_unchanged(task, updated) do
      :ok -> {:ok, updated}
      :stale -> :ignore
      {:error, _reason} = error -> error
    end
  end

  defp prepare_checkpoint(issue, existing) do
    with {:ok, task} <- ensure_effective_config(existing, issue),
         {:ok, _task, _phase} = prepared <- prepare_task(task, issue) do
      finish_prepare(issue, prepared)
    end
  end

  defp latest_phase_results(tasks) do
    Enum.reduce_while(tasks, {:ok, %{}}, fn task, {:ok, results} ->
      case Store.latest_phase_result(task["issue_id"], task["generation"]) do
        {:ok, result} -> {:cont, {:ok, Map.put(results, task["issue_id"], result)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp project_delivery_tasks(tasks, {:ok, issues}, phase_results) do
    issues_by_id = Map.new(issues, &{&1.id, &1})

    Enum.map(tasks, fn task ->
      tracker_issue =
        case Map.get(issues_by_id, task["issue_id"]) do
          %Issue{} = issue ->
            %{
              "lookup" => "found",
              "issue" => %{
                "id" => issue.id,
                "identifier" => issue.identifier,
                "title" => issue.title,
                "url" => issue.url,
                "state" => issue.state
              }
            }

          nil ->
            %{"lookup" => "missing", "issue" => nil}
        end

      %{
        "task" => task,
        "latest_phase_result" => Map.get(phase_results, task["issue_id"]),
        "tracker_issue" => tracker_issue
      }
    end)
  end

  defp project_delivery_tasks(tasks, {:error, _reason}, phase_results) do
    Enum.map(tasks, fn task ->
      %{
        "task" => task,
        "latest_phase_result" => Map.get(phase_results, task["issue_id"]),
        "tracker_issue" => %{"lookup" => "error", "issue" => nil}
      }
    end)
  end

  defp finish_prepare(issue, prepared) do
    _ = execute_pending(issue)

    case Store.pending_operations(issue.id) do
      {:ok, []} -> prepared
      _ -> :ignore
    end
  end

  defp execute_pending_operation(issue, operation, :ok) do
    case execute_operation(issue, operation) do
      {:ok, result} ->
        case Store.complete_operation(operation.key, result) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp prepare_task(nil, %Issue{} = issue) do
    if issue.state in [issue_status_value(issue, :ready), issue_status_value(issue, :building), issue_status_value(issue, :qa), issue_status_value(issue, :review)] do
      profile = issue.native_ref || %{}

      phase = initial_phase(issue)

      task = %{
        "issue_id" => issue.id,
        "execution_identity" => Issue.execution_identity(issue),
        "repository" => profile_value(profile, :repository),
        "branch" => issue.branch_name,
        "base_branch" => profile_value(profile, :base_branch),
        "required_checks" => profile_value(profile, :required_checks) || [],
        "generation" => 1,
        "phase" => phase,
        "status" => if(phase == "build", do: "building", else: phase),
        "direct_qa" => phase == "qa" and Issue.routable?(issue, ["qa"]),
        "attempts" => %{},
        "effective_config" => Skills.effective_config(issue),
        "prior_findings" => [],
        "current_sha" => nil,
        "pr_number" => nil
      }

      with {:ok, task} <- seed_initial_delivery(task, issue),
           :ok <- Store.save_task(task),
           do: {:ok, task, phase}
    else
      :ignore
    end
  end

  defp prepare_task(%{"status" => "blocked", "drop_pending" => true} = task, %Issue{} = issue) do
    case human_drop_reason(issue) do
      {:ok, reason} -> drop_task(issue, task, reason)
      :error -> :ignore
    end
  end

  defp prepare_task(%{"status" => "blocked", "qa_claim_pending" => true} = task, %Issue{} = issue) do
    if task["qa_claim_reset_seen"] == true and issue.state == status_value(task, :ready) do
      resume_direct_qa(task, issue)
    else
      :ignore
    end
  end

  defp prepare_task(%{"status" => "blocked"} = task, %Issue{} = issue) do
    if issue.state == status_value(task, :ready), do: resume_blocked_task(task, issue), else: :ignore
  end

  defp prepare_task(%{"status" => status, "stale_merge_retry" => true} = task, %Issue{} = issue)
       when status in ["review", "human_review"] do
    if issue.state == status_value(task, :ready), do: resume_human_review_task(task), else: :ignore
  end

  defp prepare_task(%{"status" => "human_review"} = task, %Issue{} = issue) do
    cond do
      issue.state != status_value(task, :ready) -> :ignore
      Issue.routable?(issue, ["qa"]) -> resume_direct_qa(task, issue)
      true -> resume_human_review_task(task)
    end
  end

  defp prepare_task(%{"status" => "finalize"} = task, %Issue{} = issue) do
    if issue.state in [status_value(task, :human_review), status_value(task, :building), status_value(task, :done), "closed"],
      do: {:ok, task, "finalize"},
      else: :ignore
  end

  defp prepare_task(%{"status" => status} = task, %Issue{} = issue) when status in ["qa", "review"] do
    if issue.state == status_value(task, :ready) and task["qa_claim_pending"] != true and task["direct_qa"] != true do
      if Issue.routable?(issue, ["qa"]), do: resume_direct_qa(task, issue), else: resume_human_review_task(task)
    else
      prepare_phase_task(task, issue)
    end
  end

  defp prepare_task(%{"status" => "building"} = task, %Issue{} = issue) do
    if issue.state in [status_value(task, :ready), status_value(task, :building)],
      do: {:ok, task, task["phase"]},
      else: :ignore
  end

  defp prepare_task(_task, _issue), do: :ignore

  defp seed_initial_delivery(task, issue) do
    if issue.state in [issue_status_value(issue, :qa), issue_status_value(issue, :review)] do
      recover_remote_delivery(task, issue, task["phase"])
    else
      with {:ok, reports} <- Tracker.phase_reports(issue),
           {task, _} = recover_remote_attempts(task, reports),
           {:ok, task} <- seed_qa_pull_request(task, issue) do
        {:ok, task}
      else
        :ignore -> {:error, :remote_phase_reports_unavailable}
        {:error, _} = error -> error
      end
    end
  end

  defp initial_phase(issue) do
    cond do
      issue.state == issue_status_value(issue, :review) -> "review"
      issue.state == issue_status_value(issue, :qa) or Issue.routable?(issue, ["qa"]) -> "qa"
      true -> "build"
    end
  end

  defp prepare_phase_task(%{"status" => "qa", "direct_qa" => true} = task, %Issue{state: issue_state}) do
    if issue_state in [status_value(task, :ready), status_value(task, :building), status_value(task, :qa)],
      do: {:ok, task, "qa"},
      else: :ignore
  end

  defp prepare_phase_task(%{"status" => status} = task, %Issue{state: issue_state}) do
    if issue_state == status_value(task, status_phase(status)) and task["phase"] in @phases,
      do: {:ok, task, task["phase"]},
      else: :ignore
  end

  @spec record_skill_readiness(Issue.t(), map(), :ok | {:error, term()}) :: {:ok, map()} | {:error, term()}
  def record_skill_readiness(%Issue{} = _issue, task, :ok) do
    task = Map.delete(task, "skill_readiness")

    with :ok <- Store.save_task(task), do: {:ok, task}
  end

  def record_skill_readiness(%Issue{} = issue, task, {:error, reason}) do
    {summary, next_step} = skill_readiness_diagnostic(issue, task, reason)
    task = Map.put(task, "skill_readiness", %{"status" => "failed", "reason" => summary, "next_step" => next_step})

    with :ok <- Store.save_task(task), do: {:ok, task}
  end

  defp ensure_effective_config(%{"effective_config" => %{"skills" => skills}} = task, _issue) when is_map(skills),
    do: {:ok, task}

  defp ensure_effective_config(%{"status" => status} = task, %Issue{} = issue)
       when status in ["building", "qa", "review", "blocked", "human_review"] do
    task = Map.put(task, "effective_config", Skills.effective_config(issue))

    with :ok <- Store.save_task(task), do: {:ok, task}
  end

  defp ensure_effective_config(task, _issue), do: {:ok, task}

  defp skill_readiness_diagnostic(issue, task, {:required_skill_unavailable, skill, path}) do
    skill_diagnostic(issue, task, skill, path, "missing", "unavailable")
  end

  defp skill_readiness_diagnostic(issue, task, {:required_skill_unavailable, skill, path, _reason}) do
    skill_diagnostic(issue, task, skill, path, "missing", "unavailable")
  end

  defp skill_readiness_diagnostic(issue, task, {:skill_fingerprint_mismatch, skill, expected, actual, path}) do
    skill_diagnostic(issue, task, skill, path, expected, actual)
  end

  defp skill_readiness_diagnostic(issue, task, {:skill_file_mismatch, skill, expected, actual, path}) do
    skill_diagnostic(issue, task, skill, path, expected, actual)
  end

  defp skill_readiness_diagnostic(issue, task, {:skill_snapshot_unavailable, _status, output}) do
    output = IO.iodata_to_binary(output)

    case parse_skill_snapshot_error(output) do
      {:file_mismatch, skill, path, expected, actual} ->
        skill_diagnostic(issue, task, skill, Path.join([".agents", "skills", skill, path]), expected, actual)

      {:fingerprint_mismatch, skill, expected, actual} ->
        path = Path.join([".agents", "skills", skill, "CHECKSUMS.sha256"])
        skill_diagnostic(issue, task, skill, path, expected, actual)

      {:missing_file, skill, path} ->
        skill_diagnostic(issue, task, skill, path, "missing", "unavailable")

      {:file_list_mismatch, skill} ->
        path = Path.join([".agents", "skills", skill])
        skill_diagnostic(issue, task, skill, path, "catalog file set", "different file set")

      nil ->
        skill_readiness_diagnostic(issue, task, output)
    end
  end

  defp skill_readiness_diagnostic(issue, _task, reason) do
    if report_locale(issue) == :es do
      {"No se pudo validar el catálogo de skills: #{inspect(reason)}",
       "Compara los archivos indicados con el catálogo elixir/priv/skills/catalog.lock.json y restaura la versión fijada; la issue seguirá en Ready y Symphony volverá a comprobar readiness."}
    else
      {"The skill catalog could not be validated: #{inspect(reason)}",
       "Compare the reported files with elixir/priv/skills/catalog.lock.json and restore the pinned version; the issue will remain Ready and Symphony will retry automatically."}
    end
  end

  defp parse_skill_snapshot_error(output) do
    patterns = [
      {:file_mismatch, ~r/Skill file checksum mismatch: \.agents\/skills\/([a-z0-9-]+)\/(.+) expected=([[:xdigit:]]+) actual=([[:xdigit:]]+)/},
      {:fingerprint_mismatch, ~r/Skill fingerprint mismatch: ([a-z0-9-]+) expected=([[:xdigit:]]+)\s+actual=([[:xdigit:]]+)/},
      {:missing_file, ~r/Required skill file is missing: (\S+)/},
      {:file_list_mismatch, ~r/Skill file list differs from the lock: ([a-z0-9-]+)/}
    ]

    Enum.find_value(patterns, fn {kind, pattern} ->
      case Regex.run(pattern, output, capture: :all_but_first) do
        nil -> nil
        captures -> {kind, captures}
      end
    end)
    |> normalize_skill_snapshot_error()
  end

  defp normalize_skill_snapshot_error({:file_mismatch, [skill, path, expected, actual]}), do: {:file_mismatch, skill, path, expected, actual}
  defp normalize_skill_snapshot_error({:fingerprint_mismatch, [skill, expected, actual]}), do: {:fingerprint_mismatch, skill, expected, actual}

  defp normalize_skill_snapshot_error({:missing_file, [path]}) do
    skill = path |> Path.split() |> Enum.at(-2)
    {:missing_file, skill, path}
  end

  defp normalize_skill_snapshot_error({:file_list_mismatch, [skill]}), do: {:file_list_mismatch, skill}
  defp normalize_skill_snapshot_error(nil), do: nil

  defp skill_diagnostic(issue, task, skill, path, expected, actual) do
    pin = Enum.find(Skills.attempt_snapshot(issue, task, task["phase"]), &(&1["name"] == skill)) || %{}
    version = pin["version"] || "unknown"
    fingerprint = pin["fingerprint"] || expected
    expected = if expected == "missing", do: fingerprint, else: expected
    actual = if actual == "unavailable", do: "missing", else: actual

    if report_locale(issue) == :es do
      {
        "La skill #{skill} no coincide con el catálogo fijado (esperado #{expected}, observado #{actual}) en #{path}.",
        "Restaura #{path} a la versión #{version} con huella #{fingerprint}; la issue seguirá en Ready y Symphony volverá a comprobar readiness."
      }
    else
      {
        "Skill #{skill} does not match the pinned catalog (expected #{expected}, observed #{actual}) at #{path}.",
        "Restore #{path} to version #{version} with fingerprint #{fingerprint}; the issue will remain Ready and Symphony will retry readiness."
      }
    end
  end

  defp seed_qa_pull_request(%{"phase" => phase} = task, issue) when phase in ["qa", "review"] do
    expected_branch = task["branch"]
    expected_base = task["base_branch"]

    case Tracker.pull_request(issue) do
      {:ok, %{number: number, branch: ^expected_branch, base: ^expected_base, sha: sha}}
      when is_integer(number) and is_binary(sha) and sha != "" ->
        {:ok, Map.merge(task, %{"current_sha" => sha, "pr_number" => number})}

      {:ok, _pull_request} ->
        {:ok, task}

      :ignore ->
        {:ok, task}

      {:error, _reason} = error ->
        error
    end
  end

  defp seed_qa_pull_request(task, _issue), do: {:ok, task}

  defp resume_blocked_task(%{"phase" => phase} = task, %Issue{} = issue) when phase in ["qa", "review"] do
    if Issue.routable?(issue, ["qa"]),
      do: resume_direct_qa(task, issue),
      else: resume_blocked_other_task(task, issue)
  end

  defp resume_blocked_task(task, _issue), do: resume_blocked_task(task)

  defp resume_direct_qa(task, issue) do
    branch = task["branch"]
    base = task["base_branch"]

    with {:ok, delivery} <- direct_qa_delivery(Tracker.pull_request(issue), branch, base),
         {:ok, [%Issue{state: state}]} <- Tracker.fetch_issues_by_ids([issue.id]),
         true <- state == status_value(task, :ready) do
      updated =
        task
        |> Map.drop(["qa_claim_pending", "qa_claim_reset_seen", "blocked_reason"])
        |> Map.merge(%{"phase" => "qa", "status" => "qa", "direct_qa" => true})
        |> Map.merge(delivery)
        |> next_direct_qa_generation(task)

      case Store.replace_task_if_unchanged(task, updated) do
        :ok -> {:ok, updated, "qa"}
        :stale -> :ignore
        {:error, _reason} = error -> error
      end
    else
      {:error, _reason} = error -> error
      _ -> :ignore
    end
  end

  defp direct_qa_delivery({:ok, %{sha: sha, number: number, branch: branch, base: base}}, branch, base)
       when is_binary(sha) and sha != "" and is_integer(number),
       do: {:ok, %{"current_sha" => sha, "pr_number" => number}}

  defp direct_qa_delivery({:error, _reason} = error, _branch, _base), do: error
  defp direct_qa_delivery(_result, _branch, _base), do: {:ok, %{"current_sha" => nil, "pr_number" => nil}}

  defp next_direct_qa_generation(updated, %{"status" => "human_review", "generation" => generation}),
    do: updated |> Map.put("generation", generation + 1) |> Map.put("attempts", %{})

  defp next_direct_qa_generation(updated, _task), do: updated

  defp resume_blocked_other_task(%{"phase" => phase, "current_sha" => current_sha} = task, issue)
       when phase in ["qa", "review"] and is_binary(current_sha) do
    case Tracker.pull_request(issue) do
      {:ok, %{sha: ^current_sha}} ->
        resume_blocked_task(task)

      {:ok, _pr} ->
        restart_blocked_task_at_build(task)

      :ignore ->
        restart_blocked_task_at_build(task)

      {:error, _reason} = error ->
        error
    end
  end

  defp resume_blocked_other_task(%{"phase" => phase} = task, _issue) when phase in ["qa", "review"],
    do: restart_blocked_task_at_build(task)

  defp restart_blocked_task_at_build(task),
    do: task |> Map.put("phase", "build") |> Map.put("current_sha", nil) |> Map.delete("direct_qa") |> resume_blocked_task()

  defp resume_blocked_task(task) do
    task = task |> Map.put("status", "building") |> Map.delete("blocked_reason")
    with :ok <- Store.save_task(task), do: {:ok, task, task["phase"]}
  end

  defp resume_human_review_task(task) do
    task =
      task
      |> Map.put("generation", task["generation"] + 1)
      |> Map.put("phase", "build")
      |> Map.put("status", "building")
      |> Map.delete("direct_qa")
      |> Map.delete("stale_merge_retry")
      |> Map.put("attempts", %{})
      |> Map.put("current_sha", nil)

    operations = if Tracker.agent_owned_writes?(), do: [], else: [operation(task, "pr_stage", %{"stage" => "draft"})]

    with :ok <- Store.commit_phase(task, "build", 0, %{"outcome" => "requeued"}, operations) do
      {:ok, task, "build"}
    end
  end

  defp finish_valid_phase(issue, task, "build", attempt, %{"outcome" => outcome, "reason" => reason} = result)
       when outcome in ["no_changes", "blocked"] do
    next = task |> Map.put("phase", "build") |> Map.put("status", "blocked") |> Map.put("blocked_reason", reason)
    ops = report_ops(next, "build", attempt, result) ++ [status_op(next, :blocked, reason, attempt)]
    commit(issue, next, "build", attempt, result, ops)
  end

  defp finish_valid_phase(issue, task, phase, attempt, %{"outcome" => "blocked"} = result)
       when phase in ["qa", "review"] do
    reason = result["reason"] || result["summary"] || "Agent requires operator intervention."
    next = task |> Map.put("phase", phase) |> Map.put("status", "blocked") |> Map.put("blocked_reason", reason)
    operations = report_ops(next, phase, attempt, result) ++ [status_op(next, :blocked, reason, attempt)]
    commit(issue, next, phase, attempt, result, operations)
  end

  defp finish_valid_phase(issue, task, "build", attempt, %{"outcome" => "ready", "sha" => sha} = result)
       when is_binary(sha) do
    with :ok <- PRBody.validate_agent_body(result["pull_request_body"], issue.id),
         :ok <- Tracker.validate_pipeline_delivery(issue, task["branch"], sha) do
      handoff = remote_handoff(result)
      pr_number = get_in(handoff, ["pull_request", "number"])
      next = task |> Map.merge(%{"phase" => "qa", "status" => "qa", "current_sha" => sha}) |> maybe_put("pr_number", pr_number)

      ops = [
        operation(next, "pull_request", %{
          "branch" => task["branch"],
          "base" => task["base_branch"],
          "sha" => sha,
          "body" => PRBody.delivery_block(result["pull_request_body"])
        }),
        report_op(next, "build", attempt, result),
        status_op(next, :qa, nil, attempt)
      ]

      commit(issue, next, "build", attempt, result, ops)
    end
  end

  defp finish_valid_phase(issue, task, "qa", attempt, %{"outcome" => "passed", "sha" => sha} = result)
       when is_binary(sha) do
    with :ok <- ensure_current_sha(task, sha),
         :ok <- validate_required_checks(task["required_checks"], result["checks"] || []) do
      next = task |> Map.merge(%{"phase" => "review", "status" => "review", "host_checks" => result["_host_checks"] || result["checks"] || []})
      operations = report_ops(next, "qa", attempt, result) ++ [status_op(next, :review, nil, attempt)]
      commit(issue, next, "qa", attempt, result, operations)
    else
      {:error, reason} ->
        result = Map.merge(result, %{"outcome" => "changes_requested", "validation_error" => inspect(reason)})
        next = %{task | "phase" => "build", "status" => "building"}
        operations = report_ops(next, "qa", attempt, result) ++ [status_op(next, :building, nil, attempt)]
        commit(issue, next, "qa", attempt, result, operations)
    end
  end

  defp finish_valid_phase(issue, task, "review", attempt, %{"outcome" => "passed", "sha" => sha} = result) do
    with :ok <- ensure_current_sha(task, sha),
         {:ok, saved} <- Store.get_task(issue.id) do
      case pending_findings(task, result) do
        [] ->
          next =
            task
            |> Map.put("phase", "review")
            |> Map.put("status", "human_review")
            |> Map.put("prior_findings", [])
            |> Map.put("stale_merge_retry", saved["stale_merge_retry"] == true)

          ops =
            report_ops(next, "review", attempt, result) ++
              [
                operation(next, "pr_stage", %{"stage" => "ready"}),
                status_op(next, :human_review, nil, attempt)
              ]

          commit(issue, next, "review", attempt, result, ops)

        findings ->
          result =
            Map.merge(result, %{
              "outcome" => "changes_requested",
              "summary" => "Autonomous Review did not resolve all prior findings.",
              "findings" => findings,
              "next_step" => "Fix the remaining findings and submit a new Build delivery."
            })

          rework_phase(issue, task, "review", attempt, result)
      end
    end
  end

  defp finish_valid_phase(issue, task, "review", attempt, %{"outcome" => "merged", "sha" => sha} = result) do
    with :ok <- ensure_current_sha(task, sha) do
      commit(issue, Map.put(task, "status", "done"), "review", attempt, result, [])
    end
  end

  defp finish_valid_phase(issue, task, "finalize", attempt, %{"outcome" => "merged", "sha" => sha} = result) do
    with :ok <- ensure_current_sha(task, sha) do
      commit(issue, Map.put(task, "status", "done"), "finalize", attempt, result, [])
    end
  end

  defp finish_valid_phase(issue, task, phase, attempt, %{"outcome" => outcome} = result)
       when phase in ["qa", "review"] and outcome in ["changes_requested", "failed", "defects_found"] do
    rework_phase(issue, task, phase, attempt, result)
  end

  defp finish_valid_phase(_issue, _task, phase, _attempt, result), do: {:error, {:invalid_phase_result, phase, result["outcome"]}}

  defp rework_phase(issue, task, phase, attempt, result) do
    next =
      task
      |> Map.put("phase", "build")
      |> Map.put("status", "building")
      |> Map.put("prior_findings", pending_findings(task, result))

    operations = report_ops(next, phase, attempt, result) ++ [status_op(next, :building, nil, attempt, phase)]
    commit(issue, next, phase, attempt, result, operations)
  end

  defp pending_findings(task, result) do
    resolutions = Map.get(result, "resolutions") || []

    (Map.get(task, "prior_findings") || [])
    |> Kernel.++(Map.get(result, "findings") || [])
    |> Enum.uniq_by(& &1["id"])
    |> Enum.reject(&Findings.resolved?(&1["id"], resolutions))
  end

  defp commit(issue, task, phase, attempt, result, operations) do
    operations = if Tracker.agent_owned_writes?(), do: [], else: operations

    case Store.commit_phase(task, phase, attempt, result, operations) do
      :ok ->
        if not Tracker.agent_owned_writes?(), do: execute_pending(issue)
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp reconcile_tasks([], _running_issue_ids), do: :ok

  defp reconcile_tasks(tasks, running_issue_ids) do
    case Tracker.fetch_issues_by_ids(Enum.map(tasks, & &1["issue_id"])) do
      {:ok, issues} ->
        issues_by_id = Map.new(issues, &{&1.id, &1})
        Enum.each(tasks, &reconcile_task(&1, issues_by_id, running_issue_ids))

      {:error, _reason} ->
        :ok
    end
  end

  defp reconcile_task(%{"issue_id" => issue_id} = task, issues_by_id, running_issue_ids) do
    case Map.get(issues_by_id, issue_id) do
      %Issue{} = issue ->
        _ = execute_pending(issue)

        if issue_id in running_issue_ids do
          :ok
        else
          reconcile_task_issue(issue, task)
        end

      _ ->
        :ok
    end
  end

  defp reconcile_task_issue(%Issue{state: "closed"} = issue, %{"status" => status} = task)
       when status not in ["done", "dropped"],
       do: reconcile_closed_issue(issue, task)

  defp reconcile_task_issue(issue, %{"status" => status} = task) do
    cond do
      issue.state == status_value(task, :done) and status != "done" ->
        reconcile_unmerged_done(issue, task, status)

      issue.state == status_value(task, :dropped) and status != "dropped" ->
        finish_human_drop(issue, task)

      true ->
        reconcile_nonterminal_task(issue, task)
    end
  end

  defp reconcile_task_issue(_issue, _task), do: :ok

  defp reconcile_nonterminal_task(issue, %{"status" => "human_review"} = task),
    do: reconcile_human_review(issue, task)

  defp reconcile_nonterminal_task(issue, %{"status" => "review", "phase" => "review"} = task) do
    if issue.state == status_value(task, :human_review),
      do: Store.save_task(Map.put(task, "status", "human_review")),
      else: reconcile_checkpoint(issue, task)
  end

  defp reconcile_nonterminal_task(issue, %{"status" => "blocked", "drop_pending" => true} = task) do
    case human_drop_reason(issue) do
      {:ok, reason} -> drop_task(issue, task, reason)
      :error -> :ok
    end
  end

  defp reconcile_nonterminal_task(issue, %{"status" => "blocked", "qa_claim_pending" => true} = task) do
    if issue.state == status_value(task, :blocked) and task["qa_claim_reset_seen"] != true,
      do: reconcile_claim_reset(task),
      else: :ok
  end

  defp reconcile_nonterminal_task(issue, task), do: reconcile_checkpoint(issue, task)

  defp reconcile_checkpoint(issue, task) do
    with {:ok, aligned} <- align_active_checkpoint(task, issue) do
      reconcile_aligned_checkpoint(issue, aligned)
    end
  end

  defp reconcile_aligned_checkpoint(issue, task) do
    case checkpoint_state_mismatch(task, issue) do
      {:mismatch, reason} -> block_checkpoint_mismatch(task, issue, reason)
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_claim_reset(task) do
    case Store.replace_task_if_unchanged(task, Map.put(task, "qa_claim_reset_seen", true)) do
      :stale -> :ok
      result -> result
    end
  end

  defp checkpoint_state_mismatch(%{"status" => "review", "stale_merge_retry" => true} = task, %Issue{state: issue_state}) do
    if issue_state == status_value(task, :ready), do: :ok, else: checkpoint_state_mismatch(task, issue_state, "review", false)
  end

  defp checkpoint_state_mismatch(%{"status" => status} = task, %Issue{state: issue_state})
       when status in ["building", "qa", "review", "finalize"] do
    with {:ok, claim_active} <- qa_claim_active(task) do
      checkpoint_state_mismatch(task, issue_state, status, claim_active)
    end
  end

  defp checkpoint_state_mismatch(_task, _issue), do: :ok

  defp qa_claim_active(%{"status" => "qa", "qa_claim_pending" => true} = task) do
    case get_in(task, ["attempts", "qa"]) do
      attempt when is_integer(attempt) -> Store.pipeline_lease_active(task["issue_id"], task["generation"], "qa", attempt)
      _ -> {:ok, false}
    end
  end

  defp qa_claim_active(_task), do: {:ok, false}

  defp checkpoint_state_mismatch(task, issue_state, status, claim_active) do
    expected_states =
      case status do
        "building" ->
          [status_value(task, :ready), status_value(task, :building)]

        "qa" ->
          qa_expected_states(task, claim_active)

        "review" ->
          [status_value(task, :review), status_value(task, :ready)]

        "finalize" ->
          [status_value(task, :human_review), status_value(task, :building), status_value(task, :done), "closed"]
      end

    if issue_state in expected_states or issue_state in [status_value(task, :done), status_value(task, :dropped), "closed"] do
      :ok
    else
      phase = task["phase"] || status

      if task["qa_claim_pending"] == true,
        do: {:mismatch, "The QA claim outcome is uncertain; move the item to Blocked and then Ready to confirm a retry."},
        else: {:mismatch, "Pipeline checkpoint is #{String.capitalize(to_string(phase))} but tracker state is #{issue_state}; review the workpad and move the item to Ready to resume safely."}
    end
  end

  defp qa_expected_states(task, claim_active) do
    cond do
      task["direct_qa"] == true and (task["qa_claim_pending"] != true or claim_active) ->
        [status_value(task, :ready), status_value(task, :building), status_value(task, :qa)]

      task["qa_claim_pending"] == true ->
        [status_value(task, :qa)]

      true ->
        [status_value(task, :qa), status_value(task, :ready)]
    end
  end

  defp block_checkpoint_mismatch(task, issue, reason) do
    blocked = task |> Map.put("status", "blocked") |> Map.put("blocked_reason", reason)

    case Store.replace_task_if_unchanged(task, blocked) do
      :ok ->
        Logger.warning("Pipeline checkpoint mismatch for issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{reason}; leaving tracker state unchanged")
        :ignore

      :stale ->
        :ignore

      {:error, _reason} = error ->
        Logger.error("Unable to persist pipeline checkpoint mismatch for issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(error)}")
        error
    end
  end

  defp reconcile_unmerged_done(issue, task, status) do
    _ = {issue, task, status}
    :ok
  end

  defp reconcile_human_review(issue, task) do
    case Tracker.pull_request(issue) do
      {:ok, %{merged: true, base: base, number: number}} ->
        if base == task["base_branch"], do: complete_merged_task(task, number), else: :ok

      {:ok, _pr} ->
        if issue.state in [status_value(task, :ready), status_value(task, :human_review), "closed"],
          do: :ok,
          else: :ok

      _ ->
        :ok
    end
  end

  defp execute_operation(issue, %{kind: "pull_request", payload: payload}) do
    attrs = %{branch: payload["branch"], base: payload["base"], sha: payload["sha"], body: payload["body"]}

    with :ok <- Tracker.validate_pipeline_delivery(issue, attrs.branch, attrs.sha),
         {:ok, pr} <- Tracker.upsert_pull_request(issue, attrs),
         :ok <- ensure_pull_request_sha(pr, attrs.sha),
         {:ok, task} when is_map(task) <- Store.get_task(issue.id),
         :ok <- Store.save_task(Map.put(task, "pr_number", pr.number)) do
      {:ok, pr}
    else
      {:error, _reason} = error -> error
      other -> {:error, {:pull_request_upsert_failed, other}}
    end
  end

  defp execute_operation(issue, %{kind: "pr_stage", payload: payload}) do
    with {:ok, %{} = pr} <- Tracker.pull_request(issue),
         {:ok, result} <- Tracker.set_pull_request_stage(issue, pr.number, String.to_existing_atom(payload["stage"])) do
      {:ok, result}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :pull_request_not_found}
    end
  end

  defp execute_operation(issue, %{kind: "project_status", payload: payload}) do
    status = status_atom(payload["status_key"] || payload["status"])

    case Tracker.set_pipeline_status(issue, status, payload["reason"]) do
      :ok -> {:ok, %{"status" => payload["status"]}}
      other -> other
    end
  end

  defp execute_operation(issue, %{kind: "report", payload: payload}) do
    case Tracker.publish_phase_report(issue, payload["marker"], payload["body"], payload["phase"]) do
      :ok -> {:ok, %{"published" => true}}
      other -> other
    end
  end

  defp ensure_pull_request_sha(%{sha: sha}, sha) when is_binary(sha), do: :ok
  defp ensure_pull_request_sha(_pr, _sha), do: {:error, :pull_request_head_sha_mismatch}

  defp complete_merged_task(task, number) do
    next = task |> Map.merge(%{"phase" => "finalize", "status" => "finalize", "pr_number" => number})
    Store.save_task(next)
  end

  defp reconcile_closed_issue(issue, task) do
    case Tracker.pull_request(issue) do
      {:ok, %{merged: true, base: base, number: number, sha: sha}} ->
        if base == task["base_branch"] and sha == task["current_sha"],
          do: complete_merged_task(task, number),
          else: :ok

      _ ->
        :ok
    end
  end

  defp drop_task(issue, task, reason) do
    report = %{
      "outcome" => "dropped",
      "reason" => reason,
      "summary" => "Work was dropped without a merged pull request.",
      "next_step" => "Create a new issue if this work should be started again."
    }

    next = task |> Map.put("status", "dropped") |> Map.put("blocked_reason", reason) |> Map.put("drop_pending", false)
    operations = [report_op(next, "dropped", 0, report), status_op(next, :dropped, nil, "drop")]
    commit(issue, next, task["phase"], 0, report, operations)
  end

  defp finish_human_drop(issue, task) do
    case human_drop_reason(issue) do
      {:ok, reason} -> drop_task(issue, task, reason)
      :error -> require_drop_reason(issue, task)
    end
  end

  defp require_drop_reason(issue, task) do
    reason = "Add a human-authored `Drop reason: <reason>` line to the issue body to confirm this discard."

    result = %{
      "outcome" => "blocked",
      "summary" => "A human reason is required before this work can be dropped.",
      "reason" => reason,
      "next_step" => "Edit the issue body with the drop reason; Symphony will then mark the task Dropped."
    }

    next = task |> Map.put("status", "blocked") |> Map.put("blocked_reason", reason) |> Map.put("drop_pending", true)
    operations = [report_op(next, task["phase"], 0, result), status_op(next, :blocked, reason, "drop_reason_required")]
    commit(issue, next, task["phase"], 0, result, operations)
  end

  defp human_drop_reason(%Issue{description: description}) when is_binary(description) do
    case Regex.run(~r/^[ \t]*Drop reason:[ \t]*(.+?)[ \t]*$/im, description) do
      [_, reason] -> {:ok, String.trim(reason)}
      _ -> :error
    end
  end

  defp human_drop_reason(_issue), do: :error

  defp report_ops(task, phase, attempt, result), do: [report_op(task, phase, attempt, result)]

  defp report_op(task, phase, attempt, result) do
    marker = "<!-- symphony:#{task["execution_identity"] || task["issue_id"]}:#{task["generation"]}:#{phase}:#{attempt} -->"
    body = marker <> "\n\n## Symphony #{String.capitalize(phase)} report\n\n" <> Jason.encode!(result, pretty: true)
    operation(task, "report", %{"marker" => marker, "body" => body, "phase" => phase})
  end

  defp status_op(task, status, reason, attempt, source_phase \\ nil),
    do:
      operation(
        task,
        "project_status",
        %{"status" => status_value(task, status), "status_key" => Atom.to_string(status), "reason" => reason},
        {source_phase || task["phase"], attempt}
      )

  defp operation(task, kind, payload, salt \\ nil) do
    key = Enum.join([task["execution_identity"] || task["issue_id"], task["generation"], task["phase"], kind, :erlang.phash2({payload, salt})], ":")
    %{key: key, issue_id: task["issue_id"], kind: kind, payload: payload}
  end

  @doc false
  @spec normalize_phase_result(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def normalize_phase_result(result, phase), do: normalize_phase_result(result, phase, :en)

  @spec normalize_phase_result(term(), String.t(), :en | :es) :: {:ok, map()} | {:error, term()}
  def normalize_phase_result(result, phase, locale) when is_map(result) do
    result = Map.new(result, fn {key, value} -> {to_string(key), value} end)
    result = normalize_remote_result(result, phase)

    result =
      if phase == "review" and is_list(result["findings"]) do
        Map.update!(result, "findings", &Enum.reject(&1, fn finding -> is_map(finding) and Findings.resolved?(finding["id"], result["resolutions"]) end))
      else
        result
      end

    result =
      if phase in ["qa", "review"] and result["outcome"] == "passed" and result["findings"] not in [nil, []],
        do:
          Map.merge(result, %{
            "outcome" => "changes_requested",
            "summary" => findings_summary(locale, phase),
            "next_step" => findings_next_step(locale)
          }),
        else: result

    if is_binary(result["outcome"]) and is_binary(result["summary"]) and valid_report?(phase, result),
      do: {:ok, result},
      else: {:error, {:invalid_phase_report, invalid_report_details(phase, result)}}
  end

  def normalize_phase_result(_result, phase, _locale),
    do: {:error, {:invalid_phase_report, %{phase: phase, report_type: :not_an_object}}}

  defp findings_summary(:es, "qa"), do: "QA encontró hallazgos que requieren corrección."
  defp findings_summary(:es, _phase), do: "La revisión encontró hallazgos que requieren corrección."
  defp findings_summary(_locale, "qa"), do: "QA reported findings that need correction."
  defp findings_summary(_locale, _phase), do: "Review reported findings that need correction."

  defp findings_next_step(:es), do: "Corrige los hallazgos y vuelve a entregar el trabajo en Build."
  defp findings_next_step(_locale), do: "Fix the findings and submit a new Build delivery."

  defp invalid_report_details(phase, result) do
    finding_keys =
      case result["findings"] do
        findings when is_list(findings) ->
          Enum.map(findings, fn
            finding when is_map(finding) -> Map.keys(finding)
            _ -> :not_an_object
          end)

        _ ->
          nil
      end

    %{phase: phase, report_keys: Map.keys(result), finding_keys: finding_keys}
  end

  defp valid_report?("build", %{"outcome" => "ready"} = result) do
    is_binary(result["sha"]) and is_binary(result["next_step"]) and
      Enum.all?(["criteria", "changes", "checks", "risks"], &is_list(result[&1]))
  end

  defp valid_report?("build", %{"outcome" => outcome} = result) when outcome in ["no_changes", "blocked"],
    do: is_binary(result["reason"])

  defp valid_report?("qa", %{"outcome" => outcome} = result) when outcome in ["passed", "changes_requested", "failed", "defects_found"] do
    is_binary(result["sha"]) and is_list(result["criteria"]) and is_list(result["changes"]) and
      is_list(result["checks"]) and valid_findings?(result["findings"]) and is_binary(result["next_step"])
  end

  defp valid_report?("qa", %{"outcome" => "blocked"} = result), do: is_binary(result["reason"])

  defp valid_report?("review", %{"outcome" => outcome} = result) when outcome in ["passed", "changes_requested", "failed", "defects_found"] do
    is_binary(result["sha"]) and valid_findings?(result["findings"]) and is_list(result["resolutions"]) and
      is_binary(result["next_step"])
  end

  defp valid_report?("review", %{"outcome" => "blocked"} = result), do: is_binary(result["reason"])

  defp valid_report?(phase, %{"outcome" => "merged"} = result) when phase in ["review", "finalize"],
    do: is_binary(result["sha"]) and is_binary(result["summary"])

  defp valid_report?("finalize", %{"outcome" => "blocked"} = result), do: is_binary(result["reason"])
  defp valid_report?(_phase, _result), do: false

  defp normalize_remote_result(result, "qa") do
    checks = result["_host_checks"] || result["checks"] || []
    result = Map.put(result, "checks", checks)

    case remote_handoff(result) do
      %{"outcome" => "blocked", "reason" => reason} = handoff when is_binary(reason) ->
        result |> Map.put("outcome", "blocked") |> Map.put("reason", reason) |> maybe_put("next_step", handoff["next_step"])

      %{"outcome" => outcome} when is_binary(outcome) ->
        Map.put(result, "outcome", outcome)

      _ ->
        result
    end
  end

  defp normalize_remote_result(result, phase) when phase in ["build", "review", "finalize"] do
    case remote_handoff(result) do
      %{"outcome" => "blocked", "reason" => reason} = handoff when is_binary(reason) ->
        result |> Map.put("outcome", "blocked") |> Map.put("reason", reason) |> maybe_put("next_step", handoff["next_step"])

      %{"outcome" => "ready", "pull_request_body" => body} when phase == "build" and is_binary(body) ->
        Map.merge(result, %{"outcome" => "ready", "pull_request_body" => body})

      %{"outcome" => outcome} when is_binary(outcome) ->
        Map.put(result, "outcome", outcome)

      _ ->
        result
    end
  end

  defp normalize_remote_result(result, _phase), do: result

  defp validate_remote_handoff(phase, result) do
    if Tracker.agent_owned_writes?(), do: validate_agent_handoff_evidence(phase, result), else: :ok
  end

  defp validate_agent_handoff_evidence(phase, result) do
    handoff = remote_handoff(result)

    with :ok <- validate_handoff_comment(handoff, result),
         :ok <- validate_handoff_outcome(handoff, result),
         :ok <- validate_phase_pull_request(phase, handoff, result),
         :ok <- validate_merge_evidence(phase, handoff, result) do
      validate_project_evidence(phase, handoff)
    end
  end

  defp validate_handoff_comment(%{"comment" => %{"id" => id, "url" => url}}, _result)
       when is_binary(id) and is_binary(url),
       do: :ok

  defp validate_handoff_comment(_handoff, %{"_workflow_errors" => errors}) when is_list(errors) and errors != [] do
    case List.last(errors) do
      %{"reason" => ":stale_agent_lease"} ->
        {:error, :stale_agent_lease}

      %{"operation" => operation, "reason" => reason} when is_binary(operation) and is_binary(reason) ->
        {:error, {:github_workflow_failed, operation, reason}}

      %{"reason" => reason} when is_binary(reason) ->
        {:error, {:github_workflow_failed, reason}}

      _ ->
        {:error, :github_handoff_comment_evidence_missing}
    end
  end

  defp validate_handoff_comment(_handoff, _result), do: {:error, :github_handoff_comment_evidence_missing}

  defp validate_handoff_outcome(%{"outcome" => outcome}, %{"outcome" => outcome}), do: :ok
  defp validate_handoff_outcome(_handoff, _result), do: {:error, :github_handoff_outcome_mismatch}

  defp validate_phase_pull_request("build", %{"outcome" => "ready"} = handoff, result) do
    pr = handoff["pull_request"]

    if valid_pull_request_evidence?(pr, result["sha"], true),
      do: :ok,
      else: {:error, :github_build_pull_request_evidence_missing}
  end

  defp validate_phase_pull_request(phase, %{"outcome" => outcome} = handoff, result)
       when phase in ["qa", "review"] and outcome in ["passed", "changes_requested", "failed", "merged"] do
    pr = handoff["pull_request"]

    if valid_pull_request_evidence?(pr, result["sha"], false),
      do: :ok,
      else: {:error, :github_pull_request_evidence_missing}
  end

  defp validate_phase_pull_request(_phase, _handoff, _result), do: :ok

  defp valid_pull_request_evidence?(pr, sha, require_draft?) do
    is_map(pr) and is_binary(pr["url"]) and pr["head_sha"] == sha and
      (not require_draft? or pr["draft"] == true)
  end

  defp validate_merge_evidence(phase, %{"outcome" => "merged"} = handoff, result)
       when phase in ["review", "finalize"] do
    pr = handoff["pull_request"]
    project = handoff["project_item"]
    closed_issue = handoff["closed_issue"]

    cond do
      not (is_map(pr) and pr["merged"] == true and pr["head_sha"] == result["sha"]) ->
        {:error, :github_merge_confirmation_missing}

      not (is_map(closed_issue) and closed_issue["state"] == "CLOSED" and is_map(project) and project["status"] == "Done") ->
        {:error, :github_merge_finalization_evidence_missing}

      true ->
        :ok
    end
  end

  defp validate_merge_evidence(_phase, _handoff, _result), do: :ok

  defp validate_project_evidence(phase, %{"project_item" => project}) when phase != "finalize" and is_map(project) do
    if is_binary(project["id"]), do: :ok, else: {:error, :github_project_evidence_missing}
  end

  defp validate_project_evidence(_phase, _handoff), do: :ok

  defp remote_handoff(%{"_remote_evidence" => evidence}) when is_list(evidence) do
    Enum.find_value(Enum.reverse(evidence), fn
      %{"outcome" => _outcome, "comment" => _comment, "project_item" => _project} = handoff -> handoff
      %{"outcome" => _outcome, "comment" => _comment, "issue" => _issue} = handoff -> handoff
      %{"evidence" => %{"outcome" => _outcome, "comment" => _comment, "project_item" => _project} = handoff} -> handoff
      %{"evidence" => %{"outcome" => _outcome, "comment" => _comment, "issue" => _issue} = handoff} -> handoff
      _ -> nil
    end)
  end

  defp remote_handoff(_result), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp valid_findings?(findings) when is_list(findings) do
    Enum.all?(findings, fn
      %{"id" => id, "reproduction" => reproduction, "criterion" => criterion} ->
        Enum.all?([id, reproduction, criterion], &(is_binary(&1) and String.trim(&1) != ""))

      _ ->
        false
    end)
  end

  defp valid_findings?(_findings), do: false

  defp validate_required_checks(required, checks) when is_list(required) and is_list(checks) do
    passed =
      Enum.reduce(checks, MapSet.new(), fn
        %{"name" => name, "status" => "passed", "evidence" => evidence}, acc
        when is_binary(name) and is_binary(evidence) ->
          if String.trim(evidence) == "", do: acc, else: MapSet.put(acc, name)

        _, acc ->
          acc
      end)

    if Enum.all?(required, &MapSet.member?(passed, &1)), do: :ok, else: {:error, :required_checks_missing_or_unavailable}
  end

  defp validate_required_checks(_required, _checks), do: {:error, :required_checks_missing_or_unavailable}

  defp ensure_current_sha(%{"current_sha" => sha}, sha) when is_binary(sha), do: :ok
  defp ensure_current_sha(_task, _sha), do: {:error, :phase_sha_mismatch}

  defp status_atom("backlog"), do: :backlog
  defp status_atom("ready"), do: :ready
  defp status_atom("building"), do: :building
  defp status_atom("qa"), do: :qa
  defp status_atom("review"), do: :review
  defp status_atom("human_review"), do: :human_review
  defp status_atom("blocked"), do: :blocked
  defp status_atom("dropped"), do: :dropped
  defp status_atom("done"), do: :done

  defp status_atom(status) do
    Enum.find_value(@statuses, fn {atom, value} -> if value == status, do: atom end)
  end

  defp status_value(_task, status), do: @statuses[status]

  defp issue_status_value(_issue, status), do: @statuses[status]

  defp status_phase("building"), do: :building
  defp status_phase("qa"), do: :qa
  defp status_phase("review"), do: :review
  defp profile_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
