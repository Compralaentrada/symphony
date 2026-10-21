defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.{AppServer, Skills}
  alias SymphonyElixir.{Config, Pipeline, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | map() | no_return()
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

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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

    selected_repo_skills =
      if is_nil(worker_host) do
        skills = Skills.select(issue)
        if Keyword.has_key?(opts, :phase), do: List.delete(skills, "code-review"), else: skills
      end

    opts = Keyword.put(opts, :selected_repo_skills, selected_repo_skills)

    with :ok <- ensure_skills_available(workspace, issue, worker_host),
         {:ok, session} <-
           AppServer.start_session(
             workspace,
             worker_host: worker_host,
             disable_tracker_tools: Keyword.has_key?(opts, :phase)
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

  defp run_pipeline_phase(session, issue, recipient, opts) do
    phase = Keyword.fetch!(opts, :phase)
    message_key = {__MODULE__, make_ref()}

    on_message = fn message ->
      send_codex_update(recipient, issue, message)

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

    prompt =
      issue
      |> PromptBuilder.build_prompt(opts)
      |> append_selected_skills(Keyword.get(opts, :selected_repo_skills), 1)
      |> Kernel.<>(
        "\n\n" <>
          pipeline_phase_instructions(phase, opts) <>
          "\nThe phase report JSON contract overrides any skill's preferred presentation format."
      )

    output_schema = phase_report_schema(phase)

    try do
      case run_phase_turn(session, prompt, issue, on_message, message_key, phase, output_schema) do
        {:ok, report} ->
          {:phase_result, report}

        {:error, {:invalid_phase_report, _details}} ->
          Process.delete(message_key)

          case run_phase_turn(
                 session,
                 phase_report_correction_prompt(),
                 issue,
                 on_message,
                 message_key,
                 phase,
                 output_schema
               ) do
            {:ok, report} -> {:phase_result, report}
            error -> error
          end

        error ->
          error
      end
    after
      Process.delete(message_key)
    end
  end

  defp run_phase_turn(session, prompt, issue, on_message, message_key, phase, output_schema) do
    case AppServer.run_turn(session, prompt, issue,
           on_message: on_message,
           output_schema: output_schema
         ) do
      {:ok, _turn} ->
        with {:ok, report} <- decode_phase_report(phase_report_text(Process.get(message_key))) do
          Pipeline.normalize_phase_result(report, Atom.to_string(phase), Pipeline.report_locale(issue))
        end

      error ->
        error
    end
  end

  defp phase_report_correction_prompt do
    """
    The previous response did not match the pipeline's required phase report. Return exactly one JSON object using the fields and allowed outcome from the preceding phase instructions, including the exact key names required for each finding. Preserve its findings and conclusions; do not repeat the work. The pipeline's JSON report contract overrides any skill's preferred prose format.
    Do not include headings, bullets, Markdown, code fences, or text outside the JSON object.
    """
  end

  defp pipeline_phase_instructions(:build, opts) do
    """
    Pipeline phase: Build.
    Implement the issue, preserve the configured branch #{Keyword.get(opts, :branch)}, and push your work to origin.
    Previously reported findings to address: #{Jason.encode!(Keyword.get(opts, :prior_findings, []), pretty: true)}.
    Use the Humanizer guidance for report values: write in the issue description's language, keep the wording direct and natural, and preserve every fact, result, and evidence item without inventing details.
    Do not create or update a pull request, change Project status, or comment on the issue; Symphony owns those writes.
    Finish with exactly one JSON object containing outcome (ready, no_changes, or blocked), summary, criteria, changes, checks, risks, next_step, reason when blocked or no_changes, and sha after pushing.
    criteria, changes, checks, and risks must be JSON arrays, even when empty. Put each risk in its own string element.
    Use sha null only for no_changes or blocked.
    """
  end

  defp pipeline_phase_instructions(:qa, opts) do
    """
    Pipeline phase: independent QA. Review and test the accepted commit #{Keyword.get(opts, :sha)} on branch #{Keyword.get(opts, :branch)}.
    Prior findings to recheck after Build: #{Jason.encode!(Keyword.get(opts, :prior_findings, []), pretty: true)}.
    Required checks: #{Enum.join(Keyword.get(opts, :required_checks, []), ", ")}.
    Symphony runs these configured checks on the workspace after your review. Do not claim their result or evidence; return an empty checks list. Each finding must include the exact keys id, reproduction, and criterion as non-empty strings.
    Use the Humanizer guidance for report values: write in the issue description's language, keep the wording direct and natural, and preserve every fact, result, and evidence item without inventing details.
    Do not modify files or write to GitHub. Finish with exactly one JSON object containing outcome (passed, changes_requested, or blocked), summary, criteria, changes, checks, findings, next_step, reason when blocked, and sha equal to the accepted commit.
    """
  end

  defp pipeline_phase_instructions(:review, opts) do
    """
    Pipeline phase: autonomous code review. Inspect the diff and accepted commit #{Keyword.get(opts, :sha)} on branch #{Keyword.get(opts, :branch)}.
    Prior finding IDs to resolve explicitly: #{Jason.encode!(Keyword.get(opts, :prior_findings, []), pretty: true)}.
    Do not invoke the repository's `code-review` skill or its Markdown report format; perform this review directly under the pipeline's JSON contract.
    Do not modify files or write to GitHub. Each finding must include the exact keys id, reproduction, and criterion as non-empty strings. Resolve prior finding ids explicitly.
    Use the Humanizer guidance for report values: write in the issue description's language, keep the wording direct and natural, and preserve every fact, result, and evidence item without inventing details.
    Finish with exactly one JSON object containing outcome (passed, changes_requested, or blocked), summary, findings, resolutions, next_step, reason when blocked, and sha equal to the accepted commit. Do not include headings, bullets, Markdown, code fences, or commentary outside that object.
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

  defp ensure_skills_available(_workspace, _issue, worker_host) when is_binary(worker_host), do: :ok

  defp ensure_skills_available(workspace, issue, nil), do: Skills.ensure_available(workspace, issue)

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

  defp append_selected_skills(prompt, selected_skills, 1) when is_list(selected_skills) do
    skills = Enum.map_join(selected_skills, "\n", &"- `#{&1}`")

    prompt <> "\n\nUse these repo-local skills when their conditions apply:\n" <> skills
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

  defp phase_report_schema(phase) when phase in [:qa, :review] do
    properties = %{
      "outcome" => %{
        "type" => "string",
        "enum" => ["passed", "changes_requested", "blocked", "failed", "defects_found"]
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
