defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.{AppServer, Skills}
  alias SymphonyElixir.{Config, Pipeline, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil
  @workspace_refresh_blockers [:project_branch_diverged, :project_branch_missing, :project_branch_dirty]

  @doc false
  @spec preflight_skills(Issue.t(), map() | nil, atom() | String.t() | nil, worker_host()) ::
          :ok | {:ok, :skills_preflighted} | {:error, term()}
  def preflight_skills(%Issue{} = issue, task, phase, worker_host \\ nil) do
    snapshot = Skills.attempt_snapshot(issue, task, phase)

    if snapshot == [] do
      :ok
    else
      opts = [phase: normalize_phase(phase), pipeline_task: task || %{}]
      task = task || %{}
      has_pull_request? = not is_nil(task["pr_number"])

      workspace_opts = [
        require_existing_project_branch: has_pull_request? and phase_with_pr?(opts),
        create_project_branch: true,
        refresh_project_branch: refresh_project_branch?(opts)
      ]

      case Workspace.create_for_issue(issue, worker_host, workspace_opts) do
        {:ok, workspace} ->
          preflight_verified_skills(workspace, snapshot, worker_host)

        {:error, reason} ->
          preflight_workspace_error(issue, snapshot, worker_host, reason)
      end
    end
  end

  defp preflight_verified_skills(workspace, snapshot, worker_host) do
    with :ok <- verify_skill_snapshot(workspace, snapshot, worker_host), do: {:ok, :skills_preflighted}
  end

  defp preflight_workspace_error(issue, snapshot, worker_host, reason) when reason in @workspace_refresh_blockers do
    case Workspace.create_for_issue(issue, worker_host, create_project_branch: false) do
      {:ok, workspace} ->
        with :ok <- verify_skill_snapshot(workspace, snapshot, worker_host) do
          {:error, {:workspace_preflight, reason}}
        end

      {:error, fallback_reason} ->
        {:error, {:workspace_preflight, fallback_reason}}
    end
  end

  defp preflight_workspace_error(_issue, _snapshot, _worker_host, reason),
    do: {:error, {:workspace_preflight, reason}}

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | map() | {:system_blocker, map()} | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:phase_result, result} ->
        result

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")
    diagnostic? = Keyword.get(opts, :diagnostic, false)

    refresh_project_branch? =
      not diagnostic? and not Keyword.get(opts, :skills_preflighted, false) and refresh_project_branch?(opts)

    task = Keyword.get(opts, :pipeline_task, %{})
    has_pull_request? = is_map(task) and not is_nil(Map.get(task, "pr_number"))

    workspace_opts = [
      require_existing_project_branch: has_pull_request? and phase_with_pr?(opts) and not diagnostic?,
      create_project_branch: not diagnostic?,
      refresh_project_branch: refresh_project_branch?,
      skip_project_profile_prepare: diagnostic?
    ]

    case Workspace.create_for_issue(issue, worker_host, workspace_opts) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
               :ok <- verify_pipeline_workspace_sha(workspace, issue, opts, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        workspace_creation_error(reason, issue, opts, has_pull_request?, refresh_project_branch?)
    end
  end

  defp workspace_creation_error(reason, issue, opts, has_pull_request?, refresh_project_branch?) do
    if Keyword.get(opts, :diagnostic, false) do
      {:error, reason}
    else
      is_missing_pr_branch? = has_pull_request? and phase_with_pr?(opts) and reason == :project_branch_missing
      refresh_blocked? = refresh_project_branch? and reason in @workspace_refresh_blockers
      profile_blocked? = match?({:repository_profile_invalid, _}, reason)

      if profile_blocked? or refresh_blocked? or is_missing_pr_branch?,
        do: {:phase_result, {:system_blocker, blocked_workspace_report(reason, issue)}},
        else: {:error, reason}
    end
  end

  defp verify_pipeline_workspace_sha(workspace, issue, opts, worker_host) do
    case {Keyword.get(opts, :diagnostic, false), Keyword.get(opts, :phase), Keyword.get(opts, :pipeline_task)} do
      {true, _, _} ->
        :ok

      {false, phase, task} when phase in [:qa, :review] and is_map(task) ->
        case Map.get(task, "current_sha") do
          sha when is_binary(sha) and sha != "" ->
            verify_pipeline_workspace_sha_at_sha(workspace, issue, sha, worker_host, phase == :qa and task["direct_qa"] == true)

          _ ->
            {:phase_result, {:system_blocker, blocked_workspace_report(:project_branch_sha_missing, issue)}}
        end

      _ ->
        :ok
    end
  end

  defp verify_pipeline_workspace_sha_at_sha(workspace, issue, sha, worker_host, require_draft?) do
    case verify_pipeline_pr_sha(issue, sha, require_draft?) do
      :ok -> verify_accepted_workspace_sha(workspace, issue, sha, worker_host)
      result -> result
    end
  end

  @doc false
  @spec verify_pipeline_workspace_sha_for_test(term(), Issue.t(), keyword(), worker_host()) ::
          :ok | {:phase_result, {:system_blocker, map()}} | {:error, term()}
  def verify_pipeline_workspace_sha_for_test(workspace, issue, opts, worker_host),
    do: verify_pipeline_workspace_sha(workspace, issue, opts, worker_host)

  defp verify_pipeline_pr_sha(issue, accepted_sha, require_draft?) do
    if Pipeline.enabled?(), do: read_pipeline_pr_sha(issue, accepted_sha, require_draft?), else: :ok
  end

  defp read_pipeline_pr_sha(issue, accepted_sha, require_draft?) do
    case Tracker.pull_request(issue) do
      {:ok, %{sha: ^accepted_sha, draft: true}} when require_draft? ->
        :ok

      {:ok, %{sha: ^accepted_sha}} when require_draft? ->
        {:phase_result, {:system_blocker, blocked_workspace_report(:project_pr_not_draft, issue)}}

      {:ok, %{sha: ^accepted_sha}} ->
        :ok

      {:ok, %{sha: observed_sha}} when is_binary(observed_sha) ->
        pipeline_sha_blocker(:project_pr_head_changed, accepted_sha, observed_sha, issue)

      {:ok, _pr} ->
        pipeline_sha_blocker(:project_pr_head_unavailable, accepted_sha, nil, issue)

      :ignore ->
        pipeline_sha_blocker(:project_pr_head_unavailable, accepted_sha, nil, issue)

      {:error, _reason} = error ->
        error
    end
  end

  defp pipeline_sha_blocker(reason, expected_sha, observed_sha, issue) do
    report = blocked_workspace_report({reason, expected_sha, observed_sha}, issue)
    {:phase_result, {:system_blocker, report}}
  end

  defp verify_accepted_workspace_sha(workspace, issue, sha, worker_host) do
    case Workspace.run_required_check(workspace, "true", sha, issue, worker_host) do
      {:ok, _evidence} ->
        :ok

      {:error, {:workspace_sha_mismatch, expected_sha, observed_sha}} ->
        workspace_sha_blocker(:project_branch_sha_mismatch, expected_sha, observed_sha, issue)

      {:error, {:workspace_dirty, expected_sha, observed_sha}} ->
        workspace_sha_blocker(:project_branch_sha_workspace_dirty, expected_sha, observed_sha, issue)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_sha_blocker(reason, expected_sha, observed_sha, issue) do
    report = blocked_workspace_report({reason, expected_sha, observed_sha}, issue)
    {:phase_result, {:system_blocker, report}}
  end

  defp blocked_workspace_report({reason, expected_sha, observed_sha}, issue)
       when reason in [
              :project_branch_sha_mismatch,
              :project_branch_sha_workspace_dirty,
              :project_pr_head_changed,
              :project_pr_head_unavailable
            ] do
    locale = Pipeline.report_locale(issue)
    {summary, next_step} = blocked_workspace_report_content(reason, locale)
    observed_sha = observed_sha || if(locale == :es, do: "desconocido", else: "unavailable")

    evidence =
      if locale == :es,
        do: "SHA esperado: #{expected_sha}; SHA observado: #{observed_sha}.",
        else: "Expected SHA: #{expected_sha}; observed SHA: #{observed_sha}."

    summary = summary <> " " <> evidence

    %{
      "outcome" => "blocked",
      "summary" => summary,
      "reason" => summary,
      "next_step" => next_step
    }
  end

  defp blocked_workspace_report({:repository_profile_invalid, reason}, issue) do
    {summary, next_step} = repository_profile_blocker_content(reason, Pipeline.report_locale(issue))

    %{
      "outcome" => "blocked",
      "summary" => summary,
      "reason" => summary,
      "next_step" => next_step
    }
  end

  defp blocked_workspace_report(reason, issue) when is_atom(reason) do
    {summary, next_step} = blocked_workspace_report_content(reason, Pipeline.report_locale(issue))

    %{
      "outcome" => "blocked",
      "summary" => summary,
      "reason" => summary,
      "next_step" => next_step
    }
  end

  defp blocked_workspace_report_content(:project_branch_diverged, :es),
    do: {"La rama guardada del workspace diverge de la rama actualizada de la PR.", "Conserva los commits locales, reconcilíalos con la rama de la PR, sube el resultado y mueve la issue a Ready."}

  defp blocked_workspace_report_content(:project_branch_diverged, _locale),
    do: {"The saved workspace branch diverges from the updated PR branch.", "Preserve the local commits, reconcile them with the PR branch, push the result, then move the issue to Ready."}

  defp blocked_workspace_report_content(:project_branch_missing, :es),
    do: {"Falta la rama guardada de la PR, tanto en local como en remoto.", "Restaura la rama de la PR o actualiza la PR y mueve la issue a Ready."}

  defp blocked_workspace_report_content(:project_branch_missing, _locale),
    do: {"The saved PR branch is missing locally and remotely.", "Restore the PR branch or update the PR, then move the issue to Ready."}

  defp blocked_workspace_report_content(:project_branch_dirty, :es),
    do: {"Hay cambios locales que impiden actualizar la rama de la PR.", "Conserva o confirma los cambios locales y mueve la issue a Ready para reintentarlo."}

  defp blocked_workspace_report_content(:project_branch_dirty, _locale),
    do: {"Local workspace changes prevent updating the PR branch.", "Preserve or commit the local changes, then move the issue to Ready to retry."}

  defp blocked_workspace_report_content(:project_branch_sha_mismatch, :es),
    do: {"El workspace no coincide con el SHA aceptado por Build.", "Restaura el workspace en el SHA aceptado y mueve la issue a Ready para reintentar QA o Review."}

  defp blocked_workspace_report_content(:project_branch_sha_mismatch, _locale),
    do: {"The workspace does not match the SHA accepted by Build.", "Restore the workspace at the accepted SHA, then move the issue to Ready to retry QA or Review."}

  defp blocked_workspace_report_content(:project_branch_sha_workspace_dirty, :es),
    do: {"El workspace tiene cambios locales sin confirmar.", "Conserva o limpia los cambios locales y mueve la issue a Ready para repetir Build, QA y Review."}

  defp blocked_workspace_report_content(:project_branch_sha_workspace_dirty, _locale),
    do: {"The workspace contains uncommitted local changes.", "Preserve or clean the local changes, then move the issue to Ready to rerun Build, QA, and Review."}

  defp blocked_workspace_report_content(:project_branch_sha_missing, :es),
    do: {"QA/Review no tiene el SHA aceptado por Build para validar el workspace.", "Mueve la issue a Ready para repetir Build con la rama actual de la PR antes de QA y Review."}

  defp blocked_workspace_report_content(:project_branch_sha_missing, _locale),
    do: {"QA/Review has no Build-accepted SHA to validate the workspace.", "Move the issue to Ready to rerun Build against the current PR branch before QA and Review."}

  defp blocked_workspace_report_content(:project_pr_not_draft, :es),
    do: {"La PR debe estar en borrador antes de ejecutar QA.", "Pasa la PR a borrador y mueve la issue a Ready para repetir QA."}

  defp blocked_workspace_report_content(:project_pr_not_draft, _locale),
    do: {"The PR must be a draft before running QA.", "Mark the PR as draft, then move the issue to Ready to retry QA."}

  defp blocked_workspace_report_content(:project_pr_head_changed, :es),
    do: {"La cabeza de la PR cambió después de que Build aceptara el SHA.", "Mueve la issue de Blocked a Ready para repetir Build, QA y Review sobre la cabeza actual de la PR."}

  defp blocked_workspace_report_content(:project_pr_head_changed, _locale),
    do: {"The PR head changed after Build accepted its SHA.", "Move the issue from Blocked to Ready to rerun Build, QA, and Review against the current PR head."}

  defp blocked_workspace_report_content(:project_pr_head_unavailable, :es),
    do: {"Symphony no pudo verificar la cabeza de la PR antes de QA/Review.", "Restaura o crea la PR y mueve la issue de Blocked a Ready para repetir Build, QA y Review."}

  defp blocked_workspace_report_content(:project_pr_head_unavailable, _locale),
    do: {"Symphony could not verify the PR head before QA/Review.", "Restore or create the PR, then move the issue from Blocked to Ready to rerun Build, QA, and Review."}

  defp repository_profile_blocker_content(:missing_base_branch, :es),
    do: {"El perfil del repositorio no configura base_branch.", "Configura la rama base del repositorio y mueve la issue de Blocked a Ready para reintentar."}

  defp repository_profile_blocker_content(:missing_base_branch, _locale),
    do: {"The repository profile does not configure base_branch.", "Configure the repository base branch, then move the issue from Blocked to Ready to retry."}

  defp repository_profile_blocker_content(:missing_prepare_command, :es),
    do: {"El perfil del repositorio no configura prepare_command.", "Configura el comando de preparación del workspace y mueve la issue de Blocked a Ready para reintentar."}

  defp repository_profile_blocker_content(:missing_prepare_command, _locale),
    do: {"The repository profile does not configure prepare_command.", "Configure the workspace preparation command, then move the issue from Blocked to Ready to retry."}

  defp repository_profile_blocker_content(:missing_required_checks, :es),
    do: {"El perfil del repositorio no configura required_checks.", "Configura al menos una comprobación requerida para este repositorio y mueve la issue de Blocked a Ready para reintentar."}

  defp repository_profile_blocker_content(:missing_required_checks, _locale),
    do: {"The repository profile does not configure required_checks.", "Configure at least one required check for this repository, then move the issue from Blocked to Ready to retry."}

  defp repository_profile_blocker_content(:invalid_required_checks, :es),
    do: {"El perfil del repositorio contiene required_checks inválidos.", "Corrige las comprobaciones requeridas y mueve la issue de Blocked a Ready para reintentar."}

  defp repository_profile_blocker_content(:invalid_required_checks, _locale),
    do: {"The repository profile contains invalid required_checks.", "Correct the required checks, then move the issue from Blocked to Ready to retry."}

  defp repository_profile_blocker_content(:duplicate_repository_profile, :es),
    do: {"Hay más de un perfil configurado para el repositorio.", "Deja un solo perfil para este repositorio y mueve la issue de Blocked a Ready para reintentar."}

  defp repository_profile_blocker_content(:duplicate_repository_profile, _locale),
    do: {"More than one profile is configured for this repository.", "Keep one profile for this repository, then move the issue from Blocked to Ready to retry."}

  defp repository_profile_blocker_content(:repository_unavailable, :es),
    do: {"No se pudo acceder al repositorio al preparar el workspace.", "Comprueba el acceso del host y la disponibilidad del repositorio, y mueve la issue de Blocked a Ready para reintentar."}

  defp repository_profile_blocker_content(:repository_unavailable, _locale),
    do: {"The repository could not be accessed while preparing the workspace.", "Check host access and repository availability, then move the issue from Blocked to Ready to retry."}

  defp repository_profile_blocker_content({:base_branch_unavailable, branch}, :es),
    do: {"La rama base configurada #{branch} no está disponible en el repositorio.", "Corrige base_branch en el perfil y mueve la issue de Blocked a Ready para reintentar."}

  defp repository_profile_blocker_content({:base_branch_unavailable, branch}, _locale),
    do: {"The configured base branch #{branch} is not available in the repository.", "Correct base_branch in the profile, then move the issue from Blocked to Ready to retry."}

  defp repository_profile_blocker_content({:prepare_command_failed, status}, :es),
    do: {"El comando prepare_command del perfil falló con código #{status}.", "Corrige el comando de preparación del workspace y mueve la issue de Blocked a Ready para reintentar."}

  defp repository_profile_blocker_content({:prepare_command_failed, status}, _locale),
    do: {"The profile prepare_command failed with exit status #{status}.", "Correct the workspace preparation command, then move the issue from Blocked to Ready to retry."}

  defp repository_profile_blocker_content(_reason, :es),
    do: {"El perfil del repositorio no está listo para preparar el workspace.", "Corrige la configuración o el acceso del perfil y mueve la issue de Blocked a Ready para reintentar."}

  defp repository_profile_blocker_content(_reason, _locale),
    do: {"The repository profile is not ready to prepare the workspace.", "Correct the profile configuration or access, then move the issue from Blocked to Ready to retry."}

  defp refresh_project_branch?(opts) do
    task = Keyword.get(opts, :pipeline_task, %{})
    Keyword.get(opts, :phase) == :build and is_map(task) and is_nil(Map.get(task, "current_sha"))
  end

  defp phase_with_pr?(opts), do: Keyword.get(opts, :phase) in [:build, :qa, :review]

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp notify_continuation_required(recipient, %Issue{id: issue_id})
       when is_pid(recipient) and is_binary(issue_id) do
    send(recipient, {:agent_continuation_required, issue_id})
  end

  defp notify_continuation_required(_recipient, _issue), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    selected_skill_snapshot =
      Skills.attempt_snapshot(issue, Keyword.get(opts, :pipeline_task), selected_skill_phase(opts))

    opts =
      opts
      |> Keyword.put(:selected_skill_snapshot, selected_skill_snapshot)
      |> Keyword.put(:selected_repo_skills, Skills.names(selected_skill_snapshot))

    opts =
      Keyword.put_new(
        opts,
        :host_checks,
        if(Keyword.get(opts, :diagnostic, false), do: [], else: run_pipeline_host_checks(workspace, issue, opts, worker_host))
      )

    opts = Keyword.put(opts, :report_locale, Pipeline.report_locale(issue))
    agent_context = github_agent_context(issue, opts)

    with :ok <- ensure_skills_available(workspace, issue, opts, worker_host),
         {:ok, session} <-
           AppServer.start_session(
             workspace,
             worker_host: worker_host,
             agent_context: agent_context
           ) do
      try do
        if Keyword.has_key?(opts, :phase) do
          run_pipeline_phase(session, issue, codex_update_recipient, opts)
        else
          do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_pipeline_host_checks(workspace, issue, opts, worker_host) do
    if Keyword.get(opts, :phase) == :qa do
      task = Keyword.get(opts, :pipeline_task, %{})

      Enum.map(task["required_checks"] || [], fn command ->
        run_pipeline_host_check(workspace, issue, worker_host, command, task["current_sha"])
      end)
    else
      []
    end
  end

  defp run_pipeline_host_check(workspace, issue, worker_host, command, current_sha) do
    case SymphonyElixir.Workspace.run_required_check(workspace, command, current_sha, issue, worker_host) do
      {:ok, evidence} ->
        %{"name" => command, "status" => "passed", "evidence" => evidence}

      {:error, {:check_failed, status}} ->
        %{
          "name" => command,
          "status" => "failed",
          "evidence" => "Symphony ran the configured check at SHA #{current_sha}; host exit status #{status}."
        }

      {:error, {:workspace_sha_mismatch, expected_sha, observed_sha}} ->
        %{
          "name" => command,
          "status" => "failed",
          "finding_id" => "workspace-sha-mismatch",
          "evidence" => "Symphony did not run the check because workspace HEAD was #{observed_sha || "unavailable"}, not accepted SHA #{expected_sha}."
        }

      {:error, {:workspace_dirty, expected_sha, observed_sha}} ->
        %{
          "name" => command,
          "status" => "failed",
          "finding_id" => "workspace-dirty",
          "evidence" => "Symphony did not run the check because the workspace had local changes at SHA #{observed_sha || "unavailable"}; accepted SHA was #{expected_sha}."
        }

      {:error, :check_unavailable} ->
        %{"name" => command, "status" => "unavailable", "evidence" => "Symphony could not execute the required check."}
    end
  end

  defp github_agent_context(issue, opts) do
    tracker = Config.settings!().tracker
    phase = Keyword.get(opts, :phase, :individual)
    diagnostic? = Keyword.get(opts, :diagnostic, false)

    %{
      issue: issue,
      lane: if(diagnostic?, do: :diagnostic, else: phase),
      task: Keyword.get(opts, :pipeline_task),
      generation: Keyword.get(opts, :generation),
      attempt: Keyword.get(opts, :phase_attempt),
      lease_phase: if(diagnostic?, do: phase),
      lease_token: Keyword.get(opts, :github_lease_token),
      host_checks: Keyword.get(opts, :host_checks, []),
      report_locale: Keyword.get(opts, :report_locale, Pipeline.report_locale(issue)),
      tracker_kind: tracker.kind,
      merge_policy: Map.get(tracker.provider, "merge_policy", "human")
    }
  end

  defp run_pipeline_phase(session, issue, recipient, opts) do
    phase = Keyword.fetch!(opts, :phase)
    message_key = {__MODULE__, make_ref()}
    evidence_key = {message_key, :remote_evidence}
    workflow_errors_key = {message_key, :workflow_errors}
    handoff_attempt_key = {message_key, :handoff_attempt}

    on_message = fn message ->
      send_codex_update(recipient, issue, message)
      capture_handoff_attempt(message, handoff_attempt_key)

      case message do
        %{event: :tool_call_completed, result: %{"evidence" => evidence}}
        when is_map(evidence) ->
          Process.put(evidence_key, [evidence | Process.get(evidence_key, [])])

        %{event: :tool_call_failed} ->
          capture_workflow_error(message, workflow_errors_key)

        _ ->
          :ok
      end

      case phase_delta(message) do
        nil ->
          :ok

        {item_id, delta} ->
          {_, deltas_by_item} = Process.get(message_key, {item_id, %{}})

          Process.put(
            message_key,
            {item_id, Map.update(deltas_by_item, item_id, [delta], &[delta | &1])}
          )
      end
    end

    try do
      run_pipeline_turn(session, issue, on_message, message_key, phase, opts)
    after
      Process.delete(message_key)
      Process.delete(evidence_key)
      Process.delete(workflow_errors_key)
      Process.delete(handoff_attempt_key)
    end
  end

  defp capture_workflow_error(
         %{
           payload: %{"params" => %{"tool" => "github_workflow", "arguments" => arguments}},
           result: %{"output" => output}
         },
         key
       )
       when is_map(arguments) and is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"error" => %{"reason" => reason}}} when is_binary(reason) ->
        error = %{"operation" => arguments["operation"], "reason" => reason}
        Process.put(key, [error | Process.get(key, [])])

      _ ->
        :ok
    end
  end

  defp capture_workflow_error(_message, _key), do: :ok

  defp run_pipeline_turn(session, issue, on_message, message_key, phase, opts) do
    evidence_key = {message_key, :remote_evidence}
    workflow_errors_key = {message_key, :workflow_errors}
    report_locale = Keyword.get(opts, :report_locale, Pipeline.report_locale(issue))
    report_language = report_language_name(report_locale)

    prompt =
      issue
      |> PromptBuilder.build_prompt(opts)
      |> append_selected_skills(Keyword.get(opts, :selected_repo_skills), 1)
      |> Kernel.<>(
        "\n\n" <>
          phase_instructions(phase, opts) <>
          "\nEvery GitHub `handoff` must include the structured `report` and the complete human-readable Markdown comment in `body`. Put the report JSON only in one hidden HTML comment: `<!-- symphony:report:json` on its own line, the JSON object, then `-->` on its own line. Escape any `-->` inside JSON string values as `--\\u003e` so the HTML comment stays hidden. Its decoded object must exactly match `report`, including the handoff outcome and any phase-specific report fields your instructions require you to copy from `read_workpad`'s `report_context`. Keep the rest of the comment readable Markdown." <>
          "\nWrite report values in #{report_language} (Spanish only for Spanish issues; English otherwise). Keep the wording direct and natural, and preserve every fact, result, and evidence item without inventing details." <>
          "\nThe phase report JSON contract overrides any skill's preferred presentation format."
      )

    result =
      case run_phase_turn(session, prompt, issue, on_message, message_key, phase, report_locale, opts) do
        {:error, {:invalid_phase_report, _details}} ->
          Process.delete(message_key)

          run_phase_turn(
            session,
            phase_report_correction_prompt(report_language),
            issue,
            on_message,
            message_key,
            phase,
            report_locale,
            opts
          )

        result ->
          result
      end

    case maybe_retry_handoff(result, session, issue, on_message, message_key, phase, opts) do
      {:ok, report} -> phase_result(report, phase, opts, evidence_key, workflow_errors_key)
      error -> error
    end
  end

  defp maybe_retry_handoff(
         {:ok, _report} = result,
         session,
         issue,
         on_message,
         message_key,
         phase,
         opts
       ) do
    evidence_key = {message_key, :remote_evidence}
    workflow_errors = Process.get({message_key, :workflow_errors}, [])

    retry_handoff? =
      Tracker.agent_owned_writes?() and not handoff_comment_evidence?(Process.get(evidence_key, [])) and
        Process.get({message_key, :handoff_attempt}) != :tool_call_completed and
        not Enum.any?(workflow_errors, &(&1["reason"] == ":stale_agent_lease"))

    if retry_handoff? do
      Process.delete(message_key)
      report_locale = Keyword.get(opts, :report_locale, Pipeline.report_locale(issue))
      report_language = report_language_name(report_locale)

      run_phase_turn(
        session,
        handoff_correction_prompt(report_language, workflow_errors),
        issue,
        on_message,
        message_key,
        phase,
        report_locale,
        opts
      )
    else
      result
    end
  end

  defp maybe_retry_handoff(result, _session, _issue, _on_message, _message_key, _phase, _opts), do: result

  defp handoff_comment_evidence?(evidence) when is_list(evidence),
    do: Enum.any?(evidence, &handoff_comment_evidence?/1)

  defp handoff_comment_evidence?(%{"evidence" => evidence}), do: handoff_comment_evidence?(evidence)

  defp handoff_comment_evidence?(%{
         "outcome" => outcome,
         "comment" => %{"id" => id, "url" => url},
         "project_item" => %{"id" => project_id}
       })
       when is_binary(outcome) and is_binary(id) and is_binary(url) and is_binary(project_id),
       do: true

  defp handoff_comment_evidence?(%{
         "outcome" => outcome,
         "comment" => %{"id" => id, "url" => url},
         "issue" => %{"id" => issue_id}
       })
       when is_binary(outcome) and is_binary(id) and is_binary(url) and is_binary(issue_id),
       do: true

  defp handoff_comment_evidence?(_evidence), do: false

  defp handoff_tool_call?(%{"tool" => "github_workflow", "arguments" => %{"operation" => "handoff"}}), do: true
  defp handoff_tool_call?(%{"name" => "github_workflow", "arguments" => %{"operation" => "handoff"}}), do: true
  defp handoff_tool_call?(_params), do: false

  defp capture_handoff_attempt(
         %{event: event, payload: %{"params" => params}},
         key
       )
       when event in [:tool_call_completed, :tool_call_failed] do
    if handoff_tool_call?(params) and
         (event == :tool_call_completed or Process.get(key) != :tool_call_completed) do
      Process.put(key, event)
    end
  end

  defp capture_handoff_attempt(_message, _key), do: :ok

  defp phase_instructions(phase, opts) do
    if Keyword.get(opts, :diagnostic, false), do: diagnostic_phase_instructions(phase, opts), else: pipeline_phase_instructions(phase, opts)
  end

  defp diagnostic_phase_instructions(phase, opts) do
    host_finding =
      case Keyword.get(opts, :system_blocker_report) do
        %{"summary" => summary} when is_binary(summary) ->
          "The host preflight observed: #{summary}. Verify it when possible, then preserve it in the workpad and blocked report."

        _ ->
          ""
      end

    """
    Pipeline lane: Diagnostic for #{phase}.
    Read the issue workpad and current-generation phase reports with `github_workflow` operation `read_workpad`. Independently inspect the task workspace and the repository's current pull request using read-only commands and GitHub reads. Diagnose why the normal phase cannot safely continue, using only saved task records and observed facts.
    #{host_finding}
    Record the diagnosis and recovery step in the persistent workpad with `github_workflow` operation `workpad`, then use `github_workflow` operation `handoff`, outcome `blocked`, with the complete report matching the #{phase} JSON schema. The host verifies and checkpoints your report.
    Do not edit files, push, merge, or change the pull request. Do not guess at missing evidence.
    """
  end

  defp run_phase_turn(session, prompt, issue, on_message, message_key, phase, report_locale, opts) do
    output_schema = phase_report_schema(phase)

    app_server_opts =
      [on_message: on_message, output_schema: output_schema]
      |> Keyword.merge(Keyword.take(opts, [:tool_executor]))

    case AppServer.run_turn(session, prompt, issue, app_server_opts) do
      {:ok, _turn} ->
        with {:ok, report} <- decode_phase_report(phase_report_text(Process.get(message_key))) do
          Pipeline.normalize_phase_result(report, Atom.to_string(phase), report_locale)
        end

      error ->
        error
    end
  end

  defp handoff_correction_prompt(report_language, workflow_errors) do
    handoff_failure =
      case Enum.find(workflow_errors, &(&1["operation"] == "handoff")) do
        %{"reason" => reason} -> "The previous GitHub handoff was rejected by the host: #{reason}."
        _ -> "No successful GitHub handoff comment was recorded by the host."
      end

    """
    #{handoff_failure}
    Make one corrected `github_workflow` call with operation `handoff`, using the existing work and report. Correct the host error and ensure the hidden JSON comment exactly matches the structured report. Do not repeat implementation or review work. If the handoff is rejected again, do not claim it succeeded; return the accurate phase report.
    Write report values in #{report_language} (Spanish only for Spanish issues; English otherwise). Preserve every fact, result, and evidence item without inventing details.
    The phase report JSON contract overrides any skill's preferred format. Return exactly one JSON object and no surrounding prose.
    """
  end

  defp phase_result(report, phase, opts, evidence_key, workflow_errors_key) do
    evidence = evidence_key |> Process.get([]) |> Enum.reverse()
    workflow_errors = workflow_errors_key |> Process.get([]) |> Enum.reverse()
    workflow_errors = if handoff_comment_evidence?(evidence), do: Enum.reject(workflow_errors, &(&1["operation"] == "handoff")), else: workflow_errors
    report = if phase == :qa, do: Map.put(report, "checks", Keyword.get(opts, :host_checks, [])), else: report

    report =
      report
      |> Map.put("_remote_evidence", evidence)
      |> Map.put("_host_checks", Keyword.get(opts, :host_checks, []))

    report = if workflow_errors == [], do: report, else: Map.put(report, "_workflow_errors", workflow_errors)
    {:phase_result, report}
  end

  defp phase_report_correction_prompt(report_language) do
    """
    The previous response did not match the pipeline's required phase report. Return exactly one JSON object using the fields and allowed outcome from the preceding phase instructions, including the exact key names required for each finding. Preserve its findings and conclusions; do not repeat the work. The pipeline's JSON report contract overrides any skill's preferred prose format.
    Write report values in #{report_language} (Spanish only for Spanish issues; English otherwise). Preserve every fact, result, and evidence item without inventing details.
    The task's Markdown requirement applies only to GitHub comments; this response is the internal phase result.
    Do not include headings, bullets, Markdown, code fences, or text outside the JSON object.
    """
  end

  defp report_language_name(:es), do: "Spanish"
  defp report_language_name(_locale), do: "English"

  defp pipeline_phase_instructions(:build, _opts) do
    """
    Pipeline phase: Build.
    Before any other GitHub write or code edit, call `github_workflow` with operation `claim`; stop if the claim is rejected. This claims an item dispatched from Ready by moving it to Building.
    Then read the issue's workpad and current-generation phase reports with `github_workflow` operation `read_workpad` before editing. Use those task records for prior findings and decisions. Work on the branch already checked out for this task and push your work to origin.
    Fetch the configured base branch and merge it into the task branch before validation. Resolve any conflicts, or hand off `blocked` with the conflict and recovery instructions if they cannot be resolved. Run the required checks on the updated branch.
    Implement the issue using the accepted task context recorded on the issue. Copy branch, base branch, and required checks from `read_workpad`'s `report_context.task` into your report; include the pushed SHA.
    Before editing, create or update the persistent issue workpad with `github_workflow` operation `workpad` and record the plan.
    Before handoff, read `.github/pull_request_template.md` in the task repository and write a complete PR description in `report.pull_request_body`: keep every section in template order, respect its length guidance, replace every placeholder, and include `Fixes #<issue-number>` on its own line. Set `body_file=$(mktemp)`, save that exact description without Symphony delivery markers to `$body_file`, and run `(cd elixir && mise exec -- mix pr_body.check --file "$body_file")`.
    After pushing, call `github_workflow` with operation `handoff`, outcome `ready`, and your report plus the separate issue-comment Markdown body. The comment body must contain one hidden `symphony:report:json` HTML comment whose JSON matches the report, including `pull_request_body`; the host validates and writes `report.pull_request_body` as the draft PR description, then moves the Project item to QA.
    For `no_changes` or `blocked`, hand off that result with a concise reason. Never merge a PR.
    Finish with exactly one JSON object containing outcome (ready, no_changes, or blocked), summary, criteria, changes, checks, risks, next_step, reason when blocked or no_changes, sha after pushing, and pull_request_body for ready.
    criteria, changes, checks, and risks must be JSON arrays, even when empty. Put each risk in its own string element.
    Use sha null only for no_changes or blocked.
    """
  end

  defp pipeline_phase_instructions(:qa, _opts) do
    """
    Pipeline phase: independent QA. Before any other GitHub write, call `github_workflow` with operation `claim`; stop if the claim is rejected. This moves a requeued Ready item to QA and confirms an item already in QA. On a direct `qa` route there is no Build report; use `report_context.task` for the accepted commit, branch, required checks, and PR. Then read the issue's workpad and current-generation Build reports with `github_workflow` operation `read_workpad`; use the saved task records to identify the accepted commit, branch, required checks, and prior findings.
    Symphony runs the configured host checks on the accepted SHA. `read_workpad` returns the authoritative `report_context.host_checks`, required checks, and locale-specific canonical QA text; copy the checks exactly into your report and hidden JSON. Do not modify files or invent check results. Each finding must include the exact keys id, reproduction, and criterion as non-empty strings.
    Update the persistent workpad with QA evidence and findings using `github_workflow` operation `workpad`.
    Call `github_workflow` with operation `handoff`, your QA report, and the complete Markdown body. Choose the outcome using the required checks and authoritative host evidence in `report_context`; use its canonical QA text when Symphony's check or finding rules change the summary, reason, or next step. Symphony advances only when every required check passed. Finish with exactly one JSON object containing outcome (passed, changes_requested, or blocked), summary, criteria, changes, checks, findings, next_step, reason when blocked, and sha equal to the accepted commit.
    """
  end

  defp pipeline_phase_instructions(:review, _opts) do
    merge_policy = Map.get(Config.settings!().tracker.provider, "merge_policy", "human")

    """
    Pipeline phase: autonomous code review. Before any other GitHub write, call `github_workflow` with operation `claim`; stop if the claim is rejected. This moves a requeued Ready item to Review and confirms an item already in Review. Then read the issue's workpad and all current-generation QA reports with `github_workflow` operation `read_workpad` before reviewing. Use those task records and `report_context.task` to identify the accepted commit, branch, QA findings, and findings to resolve. Include the task's branch, base branch, PR number, and current SHA in your report, plus every prior finding not explicitly resolved.
    Use the QA report's host-check evidence for its recorded SHA; do not require a separate GitHub status context for Symphony's host-run check.
    Do not invoke the repository's `code-review` skill or its Markdown report format; perform this review directly under the pipeline's JSON contract.
    The task's Markdown requirement applies only to GitHub comments; this response is the internal phase result.
    Do not modify files. Each finding must include the exact keys id, reproduction, and criterion as non-empty strings. Resolve prior finding ids explicitly.
    Update the persistent workpad with review findings and resolutions using `github_workflow` operation `workpad`.
    The configured merge policy is #{merge_policy}. With human merge policy, hand off outcome `passed` to prepare the PR for human review. With auto merge policy, first hand off `passed`, then call `request_merge`; if the host confirms the merge, hand off outcome `merged` so the host verifies it before closing the issue and moving the item to Done. If the gate reports `pull_request_base_not_in_head` or `pull_request_base_sha_mismatch`, finish with the existing `passed` report; the host requeues the task for Build. For other gate failures, leave the PR in Human Review.
    Finish with exactly one JSON object containing outcome (passed, merged, changes_requested, or blocked), summary, findings, resolutions, next_step, reason when blocked, and sha equal to the accepted commit.
    """
  end

  defp pipeline_phase_instructions(:finalize, _opts) do
    """
    Pipeline phase: Finalize a human-merged pull request. Read the issue's workpad and current-generation Build, QA, and Review reports with `github_workflow` operation `read_workpad`. Use the Review report's persisted pull request number, base branch, and accepted SHA to verify the merge with GitHub read tools.
    Do not modify files. Call `github_workflow` with operation `handoff`, outcome `merged`, and a short report using the accepted SHA from the Review report. The host closes the issue and moves its Project item to Done only after verifying the remote merge.
    Finish with exactly one JSON object containing outcome `merged`, summary, sha, and next_step.
    """
  end

  defp phase_delta(%{payload: %{"method" => "item/agentMessage/delta", "params" => params}})
       when is_map(params) do
    delta = Map.get(params, "delta") || get_in(params, ["msg", "delta"])
    item_id = Map.get(params, "itemId") || get_in(params, ["msg", "itemId"])

    if is_binary(item_id) and is_binary(delta), do: {item_id, delta}
  end

  defp phase_delta(_message), do: nil

  defp phase_report_text({item_id, deltas_by_item}) do
    deltas_by_item
    |> Map.get(item_id, [])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp phase_report_text(_state), do: ""

  defp decode_phase_report(text) do
    json =
      text
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```$/, "")

    case Jason.decode(json) do
      {:ok, report} when is_map(report) -> {:ok, normalize_phase_report(report)}
      _ -> {:error, {:invalid_phase_report, String.slice(text, -500, 500)}}
    end
  end

  defp normalize_phase_report(%{"risks" => risk} = report) when is_binary(risk),
    do: Map.put(report, "risks", [risk])

  defp normalize_phase_report(report), do: report

  defp ensure_skills_available(workspace, _issue, opts, worker_host) do
    verify_skill_snapshot(workspace, Keyword.fetch!(opts, :selected_skill_snapshot), worker_host)
  end

  defp verify_skill_snapshot(workspace, snapshot, nil), do: Skills.verify_snapshot(workspace, snapshot)
  defp verify_skill_snapshot(workspace, snapshot, worker_host), do: Workspace.verify_skill_snapshot(workspace, snapshot, worker_host)

  defp selected_skill_phase(opts), do: if(Keyword.get(opts, :diagnostic, false), do: :diagnostic, else: Keyword.get(opts, :phase))

  defp normalize_phase(phase) when is_atom(phase), do: phase
  defp normalize_phase(phase) when phase in ["build", "qa", "review", "diagnostic", "finalize"], do: String.to_existing_atom(phase)
  defp normalize_phase(_phase), do: nil

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")
          notify_continuation_required(codex_update_recipient, refreshed_issue)

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    issue
    |> PromptBuilder.build_prompt(opts)
    |> append_selected_skills(Keyword.get(opts, :selected_repo_skills), 1)
    |> append_individual_github_instructions(issue, opts)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp append_individual_github_instructions(prompt, issue, opts) do
    if Config.settings!().tracker.kind in ["github", "github_projects"] and not Keyword.has_key?(opts, :phase) do
      release = if Config.settings!().tracker.kind == "github", do: " After the handoff, release your claim.", else: ""

      github_instructions = """
      For this GitHub task, create or update the persistent issue workpad with `github_workflow` operation `workpad`, then claim the issue before working. Preserve branch #{issue.branch_name}, push it to origin, and read `.github/pull_request_template.md` in the task repository.
      Put the complete PR description in `report.pull_request_body`, keep every section in template order, follow its length guidance, replace all placeholders, include `Fixes #<issue-number>` for this issue, and omit Symphony delivery markers. Set `body_file=$(mktemp)`, save that exact text to `$body_file`, and run `(cd elixir && mise exec -- mix pr_body.check --file "$body_file")`.
      Then hand off outcome `ready` with a separate human-readable Markdown issue-comment `body` containing one hidden `symphony:report:json` HTML comment. Put the marker on its own line, the exact report JSON next, and `-->` on its own line; escape any `-->` in JSON strings as `--\\u003e` and make the decoded JSON match `report`, including `pull_request_body`. The host validates and writes that description to the draft PR. For `blocked` or `no_changes`, hand off that result with a reason and do not create a PR. Use `github_workflow` for every GitHub write; the default merge policy is human review.
      """

      prompt <>
        "\n\n" <>
        github_instructions <>
        release
    else
      prompt
    end
  end

  defp append_selected_skills(prompt, [], 1) do
    prompt <>
      "\n\nSymphony selected no task-specific repo skills for this unattended session. Do not load unlisted task-specific skills; follow separate repository workflow instructions for operational skills when relevant."
  end

  defp append_selected_skills(prompt, selected_skills, 1) when is_list(selected_skills) do
    skills = Enum.map_join(selected_skills, "\n", &"- `#{&1}`")

    prompt <>
      "\n\nUse only these task-specific repo skills selected by Symphony for this unattended session:\n" <>
      skills <>
      "\nFollow separate repository workflow instructions for operational skills such as pull, commit, and push when relevant."
  end

  defp append_selected_skills(prompt, _selected_skills, _turn_number), do: prompt

  defp phase_report_schema(:build) do
    report_schema(%{
      "outcome" => %{"type" => "string", "enum" => ["ready", "no_changes", "blocked"]},
      "summary" => %{"type" => "string"},
      "criteria" => string_array_schema(),
      "changes" => string_array_schema(),
      "checks" => string_array_schema(),
      "risks" => string_array_schema(),
      "next_step" => %{"type" => "string"},
      "reason" => %{"type" => ["string", "null"]},
      "sha" => %{"type" => ["string", "null"]}
    })
  end

  defp phase_report_schema(:finalize) do
    report_schema(%{
      "outcome" => %{"type" => "string", "enum" => ["merged"]},
      "summary" => %{"type" => "string"},
      "sha" => %{"type" => "string"},
      "next_step" => %{"type" => "string"}
    })
  end

  defp phase_report_schema(phase) when phase in [:qa, :review] do
    properties = %{
      "outcome" => %{
        "type" => "string",
        "enum" => ["passed", "changes_requested", "blocked", "failed", "defects_found"] ++ if(phase == :review, do: ["merged"], else: [])
      },
      "summary" => %{"type" => "string"},
      "findings" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "reproduction" => %{"type" => "string"},
            "criterion" => %{"type" => "string"}
          },
          "required" => ["id", "reproduction", "criterion"],
          "additionalProperties" => false
        }
      },
      "next_step" => %{"type" => "string"},
      "reason" => %{"type" => ["string", "null"]},
      "sha" => %{"type" => "string"}
    }

    phase_properties =
      case phase do
        :qa ->
          %{
            "criteria" => string_array_schema(),
            "changes" => string_array_schema(),
            "checks" => string_array_schema()
          }

        :review ->
          %{"resolutions" => string_array_schema()}
      end

    report_schema(Map.merge(properties, phase_properties))
  end

  defp report_schema(properties) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }
  end

  defp string_array_schema, do: %{"type" => "array", "items" => %{"type" => "string"}}

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
