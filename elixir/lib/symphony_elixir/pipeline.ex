defmodule SymphonyElixir.Pipeline do
  @moduledoc false

  alias SymphonyElixir.{Config, Pipeline.Store, Tracker}
  alias SymphonyElixir.Tracker.Issue

  @phases ~w(build qa review)
  @statuses %{
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
    values = Map.get(tracker.provider, "status_values", %{})
    tracker.kind == "github_projects" and Enum.all?(~w(qa review human_review dropped), &Map.has_key?(values, &1))
  end

  @spec reconcile() :: :ok | {:error, term()}
  def reconcile do
    with {:ok, tasks} <- Store.tasks() do
      Enum.each(tasks, &reconcile_task/1)
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
  def finish_phase(%Issue{} = issue, task, phase, attempt, result) do
    case normalize_phase_result(result, phase) do
      {:ok, result} ->
        finish_valid_phase(issue, task, phase, attempt, result)

      {:error, reason} ->
        _ = Store.interrupt_phase(issue.id, task["generation"], phase, attempt)
        {:error, reason}
    end
  end

  @spec block_phase(Issue.t(), map(), String.t(), pos_integer(), String.t()) :: :ok | {:error, term()}
  def block_phase(%Issue{} = issue, task, phase, attempt, reason) do
    result = %{
      "outcome" => "blocked",
      "summary" => "An operator must resolve an intervention before this phase can continue.",
      "reason" => reason,
      "next_step" => "Resolve the blocker and move the Project item to Ready.",
      "sha" => task["current_sha"]
    }

    next = task |> Map.put("phase", phase) |> Map.put("status", "blocked") |> Map.put("blocked_reason", reason)
    operations = report_ops(next, phase, attempt, result) ++ [status_op(next, :blocked, reason, attempt)]
    commit(issue, next, phase, attempt, result, operations)
  end

  @spec execute_pending(Issue.t()) :: :ok | {:error, term()}
  def execute_pending(%Issue{} = issue) do
    case Store.pending_operations(issue.id) do
      {:ok, operations} -> Enum.reduce_while(operations, :ok, &execute_pending_operation(issue, &1, &2))
      {:error, _reason} = error -> error
    end
  end

  defp prepare_from_checkpoint(issue, existing) do
    _ = execute_pending(issue)

    case Store.pending_operations(issue.id) do
      {:ok, []} ->
        case prepare_task(existing, issue) do
          {:ok, _task, _phase} = prepared -> finish_prepare(issue, prepared)
          other -> other
        end

      _ ->
        :ignore
    end
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
    if issue.state in [issue_status_value(issue, :ready), issue_status_value(issue, :building)] do
      profile = issue.native_ref || %{}

      task = %{
        "issue_id" => issue.id,
        "repository" => profile_value(profile, :repository),
        "branch" => issue.branch_name,
        "base_branch" => profile_value(profile, :base_branch),
        "required_checks" => profile_value(profile, :required_checks) || [],
        "status_values" => profile_value(profile, :status_values) || %{},
        "generation" => 1,
        "phase" => "build",
        "status" => "building",
        "attempts" => %{},
        "prior_findings" => [],
        "current_sha" => nil,
        "pr_number" => nil
      }

      with :ok <- Store.save_task(task), do: {:ok, task, "build"}
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

  defp prepare_task(%{"status" => "blocked"} = task, %Issue{} = issue) do
    if issue.state == status_value(task, :ready), do: resume_blocked_task(task), else: :ignore
  end

  defp prepare_task(%{"status" => "human_review"} = task, %Issue{} = issue) do
    if issue.state == status_value(task, :ready), do: resume_human_review_task(task), else: :ignore
  end

  defp prepare_task(%{"status" => "building"} = task, %Issue{} = issue) do
    if issue.state in [status_value(task, :ready), status_value(task, :building)],
      do: {:ok, task, task["phase"]},
      else: :ignore
  end

  defp prepare_task(%{"status" => status} = task, %Issue{state: issue_state})
       when status in ["building", "qa", "review"] do
    phase = task["phase"]

    if issue_state == status_value(task, status_phase(status)) and phase in @phases,
      do: {:ok, task, phase},
      else: :ignore
  end

  defp prepare_task(_task, _issue), do: :ignore

  defp resume_blocked_task(task) do
    task = Map.put(task, "status", "building")
    with :ok <- Store.save_task(task), do: {:ok, task, task["phase"]}
  end

  defp resume_human_review_task(task) do
    task =
      task
      |> Map.put("generation", task["generation"] + 1)
      |> Map.put("phase", "build")
      |> Map.put("status", "building")
      |> Map.put("attempts", %{})
      |> Map.put("current_sha", nil)

    operations = [operation(task, "pr_stage", %{"stage" => "draft"})]

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
    with :ok <- Tracker.validate_pipeline_delivery(issue, task["branch"], sha) do
      next = %{task | "phase" => "qa", "status" => "qa", "current_sha" => sha}

      ops = [
        operation(next, "pull_request", %{
          "branch" => task["branch"],
          "base" => task["base_branch"],
          "sha" => sha,
          "body" => pull_request_body(issue, result)
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
      next = %{task | "phase" => "review", "status" => "review"}
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
    with :ok <- ensure_current_sha(task, sha) do
      case pending_findings(task, result) do
        [] ->
          next =
            task
            |> Map.put("phase", "review")
            |> Map.put("status", "human_review")
            |> Map.put("prior_findings", [])

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
    resolved_ids = MapSet.new(Map.get(result, "resolutions") || [])

    (Map.get(task, "prior_findings") || [])
    |> Kernel.++(Map.get(result, "findings") || [])
    |> Enum.uniq_by(& &1["id"])
    |> Enum.reject(&MapSet.member?(resolved_ids, &1["id"]))
  end

  defp commit(issue, task, phase, attempt, result, operations) do
    case Store.commit_phase(task, phase, attempt, result, operations) do
      :ok ->
        _ = execute_pending(issue)
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp reconcile_task(%{"issue_id" => issue_id} = task) do
    case Tracker.fetch_issues_by_ids([issue_id]) do
      {:ok, [issue | _]} ->
        _ = execute_pending(issue)
        reconcile_task_issue(issue, task)

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

  defp reconcile_nonterminal_task(issue, %{"status" => "blocked", "drop_pending" => true} = task) do
    case human_drop_reason(issue) do
      {:ok, reason} -> drop_task(issue, task, reason)
      :error -> :ok
    end
  end

  defp reconcile_nonterminal_task(_issue, _task), do: :ok

  defp reconcile_unmerged_done(issue, task, status) do
    case expected_status(status) do
      nil -> :ok
      expected -> persist_status(issue, task, expected, "reject_unmerged_done")
    end
  end

  defp reconcile_human_review(issue, task) do
    case Tracker.pull_request(issue) do
      {:ok, %{merged: true, base: base}} ->
        if base == task["base_branch"], do: complete_merged_task(issue, task), else: :ok

      {:ok, _pr} ->
        if issue.state in [status_value(task, :ready), status_value(task, :human_review), "closed"],
          do: :ok,
          else: persist_status(issue, task, :human_review, "reconcile_human_review")

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

  defp pull_request_body(issue, result) do
    """
    <!-- symphony:delivery -->

    Fixes #{issue.id}

    ## Summary

    #{result["summary"]}

    ## Acceptance criteria

    #{markdown_items(result["criteria"])}

    ## Changes

    #{markdown_items(result["changes"])}

    ## Checks

    #{markdown_items(result["checks"])}

    ## Evidence

    - Build SHA: `#{result["sha"]}`

    ## Risks and limitations

    #{markdown_items(result["risks"])}

    ## Next step

    #{result["next_step"]}
    """
    |> String.trim()
  end

  defp markdown_items(items) when is_list(items) do
    case items do
      [] -> "- None reported."
      items -> Enum.map_join(items, "\n", &("- " <> markdown_item(&1)))
    end
  end

  defp markdown_items(_items), do: "- None reported."
  defp markdown_item(item) when is_binary(item), do: item
  defp markdown_item(item), do: Jason.encode!(item)

  defp persist_status(issue, task, status, salt) do
    with :ok <- Store.save_task_with_operations(task, [status_op(task, status, nil, salt)]) do
      execute_pending(issue)
    end
  end

  defp complete_merged_task(issue, task) do
    next = %{task | "status" => "done"}
    operation = status_op(next, :done, nil, "confirmed_merge")

    with :ok <- Store.save_task_with_operations(next, [operation]) do
      execute_pending(issue)
    end
  end

  defp reconcile_closed_issue(issue, task) do
    case Tracker.pull_request(issue) do
      {:ok, %{merged: true, base: base}} ->
        if base == task["base_branch"] do
          complete_merged_task(issue, task)
        else
          drop_task(issue, task, "GitHub issue closed before the pull request was merged into the configured base branch.")
        end

      {:ok, _pr} ->
        drop_task(issue, task, close_reason(issue))

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

  defp close_reason(issue) do
    case human_drop_reason(issue) do
      {:ok, reason} ->
        reason

      :error ->
        state_reason = profile_value(issue.native_ref || %{}, :issue_state_reason)
        if is_binary(state_reason) and state_reason != "", do: "GitHub issue closed with reason #{state_reason} before the PR merged.", else: "GitHub issue closed by a human before the PR merged."
    end
  end

  defp expected_status("blocked"), do: :blocked
  defp expected_status("human_review"), do: :human_review
  defp expected_status("qa"), do: :qa
  defp expected_status("review"), do: :review
  defp expected_status("dropped"), do: :dropped
  defp expected_status("building"), do: :building
  defp expected_status(_status), do: nil

  defp report_ops(task, phase, attempt, result), do: [report_op(task, phase, attempt, result)]

  defp report_op(task, phase, attempt, result) do
    marker = "<!-- symphony:#{task["issue_id"]}:#{task["generation"]}:#{phase}:#{attempt} -->"
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
    key = Enum.join([task["issue_id"], task["generation"], task["phase"], kind, :erlang.phash2({payload, salt})], ":")
    %{key: key, issue_id: task["issue_id"], kind: kind, payload: payload}
  end

  @doc false
  @spec normalize_phase_result(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def normalize_phase_result(result, phase) when is_map(result) do
    result = Map.new(result, fn {key, value} -> {to_string(key), value} end)

    result =
      if phase in ["qa", "review"] and result["outcome"] == "passed" and result["findings"] not in [nil, []],
        do:
          Map.merge(result, %{
            "outcome" => "changes_requested",
            "summary" => "#{String.upcase(phase)} reported findings that need correction.",
            "next_step" => "Fix the findings and submit a new Build delivery."
          }),
        else: result

    if is_binary(result["outcome"]) and is_binary(result["summary"]) and valid_report?(phase, result),
      do: {:ok, result},
      else: {:error, {:invalid_phase_report, invalid_report_details(phase, result)}}
  end

  def normalize_phase_result(_result, phase),
    do: {:error, {:invalid_phase_report, %{phase: phase, report_type: :not_an_object}}}

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
  defp valid_report?(_phase, _result), do: false

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

  defp status_value(task, status), do: Map.get(task["status_values"] || %{}, Atom.to_string(status)) || @statuses[status]

  defp issue_status_value(issue, status) do
    statuses = profile_value(issue.native_ref || %{}, :status_values) || %{}
    Map.get(statuses, Atom.to_string(status)) || @statuses[status]
  end

  defp status_phase("building"), do: :building
  defp status_phase("qa"), do: :qa
  defp status_phase("review"), do: :review
  defp profile_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
