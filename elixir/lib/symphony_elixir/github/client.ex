defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for repository issue polling.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.AgentReport
  alias SymphonyElixir.Pipeline.Store
  alias SymphonyElixir.PRBody
  alias SymphonyElixir.Tracker.Issue

  @default_api_url "https://api.github.com"
  @api_version "2022-11-28"
  @page_size 100
  @user_agent "symphony"

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    [
      "GITHUB_TOKEN",
      "GH_TOKEN",
      "GITHUB_ENTERPRISE_TOKEN",
      "GH_ENTERPRISE_TOKEN" | env_reference_names([provider["token"]])
    ]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, Config.settings!().tracker, &perform_request/5)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issues_by_ids(issue_ids, Config.settings!().tracker, &perform_request/5)
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, params, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(params) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, github_settings} <- settings(tracker_settings) do
      request_fun.(method, path, params, body, github_settings)
    end
  end

  @spec agent_operation(Issue.t(), map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def agent_operation(%Issue{} = issue, context, operation, arguments, opts)
      when is_map(context) and is_binary(operation) and is_map(arguments) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    base_request = Keyword.get(opts, :github_rest, &perform_request/5)

    with :ok <- validate_agent_lease(context),
         {:ok, settings} <- settings(tracker_settings),
         :ok <- ensure_agent_repository(issue, settings) do
      request_fun = agent_request(context, base_request)
      dispatch_agent_operation(issue, context, operation, arguments, settings, request_fun)
    end
  end

  defp dispatch_agent_operation(issue, context, operation, arguments, settings, request_fun) do
    case operation do
      "claim" -> agent_claim(issue, context, settings, request_fun)
      "release_claim" -> agent_release_claim(issue, context, settings, request_fun)
      "workpad" -> agent_workpad(issue, arguments, settings, request_fun)
      "handoff" -> agent_handoff(issue, context, arguments, settings, request_fun)
      "create_follow_up_issue" -> create_follow_up_issue(issue, context, arguments, settings, request_fun)
      _ -> {:error, :unsupported_github_workflow_operation}
    end
  end

  defp agent_request(context, request_fun) do
    fn method, path, params, body, request_settings ->
      with_valid_agent_lease(context, fn -> request_fun.(method, path, params, body, request_settings) end)
    end
  end

  defp with_valid_agent_lease(context, request_fun) do
    with :ok <- validate_agent_lease(context), do: request_fun.()
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, repo) when is_map(issue) and is_binary(repo) do
    normalize_issue(issue, repo)
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, tracker_settings, request_fun)
      when is_list(state_names) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_states(state_names, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, tracker_settings, request_fun)
      when is_list(issue_ids) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_ids(issue_ids, tracker_settings, request_fun)
  end

  defp fetch_issues_by_states(state_names, tracker_settings, request_fun) do
    normalized_states = state_names |> Enum.map(&normalize_state/1) |> MapSet.new()

    case github_state_query(normalized_states) do
      nil ->
        {:ok, []}

      state_query ->
        with {:ok, github_settings} <- settings(tracker_settings) do
          do_fetch_pages(github_settings, state_query, normalized_states, 1, request_fun, [])
        end
    end
  end

  defp fetch_issues_by_ids(issue_ids, tracker_settings, request_fun) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, github_settings} <- settings(tracker_settings) do
          fetch_issue_ids(ids, github_settings, request_fun, [])
        end
    end
  end

  defp do_fetch_pages(settings, state_query, requested_states, page, request_fun, acc) do
    params = %{
      "state" => state_query,
      "per_page" => @page_size,
      "page" => page,
      "sort" => "created",
      "direction" => "asc"
    }

    with {:ok, payload} <-
           request_with_settings(
             "GET",
             repository_issues_path(settings),
             params,
             nil,
             settings,
             request_fun,
             false
           ),
         true <- is_list(payload) or {:error, :github_unknown_payload} do
      issues = normalize_state_page(payload, settings.repo, requested_states)
      updated_acc = [issues | acc]

      if length(payload) < @page_size do
        {:ok, updated_acc |> Enum.reverse() |> List.flatten()}
      else
        do_fetch_pages(settings, state_query, requested_states, page + 1, request_fun, updated_acc)
      end
    end
  end

  defp fetch_issue_ids([], _settings, _request_fun, acc), do: {:ok, Enum.reverse(acc)}

  defp fetch_issue_ids([id | rest], settings, request_fun, acc) do
    with {:ok, issue_number} <- parse_issue_number(id),
         {:ok, payload} <-
           request_with_settings(
             "GET",
             repository_issue_path(settings, issue_number),
             %{},
             nil,
             settings,
             request_fun,
             true
           ) do
      continue_issue_id_fetch(payload, rest, settings, request_fun, acc)
    end
  end

  defp continue_issue_id_fetch(:not_found, rest, settings, request_fun, acc) do
    fetch_issue_ids(rest, settings, request_fun, acc)
  end

  defp continue_issue_id_fetch(%{} = raw_issue, rest, settings, request_fun, acc) do
    case normalize_issue(raw_issue, settings.repo) do
      %Issue{} = issue -> fetch_issue_ids(rest, settings, request_fun, [issue | acc])
      nil -> {:error, :github_unknown_payload}
    end
  end

  defp continue_issue_id_fetch(_payload, _rest, _settings, _request_fun, _acc) do
    {:error, :github_unknown_payload}
  end

  defp normalize_state_page(payload, repo, requested_states) do
    issues = Enum.map(payload, &normalize_issue(&1, repo))
    malformed_count = Enum.count(issues, &is_nil/1)

    if malformed_count > 0 do
      Logger.warning("Dropping malformed GitHub issue records count=#{malformed_count}")
    end

    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&MapSet.member?(requested_states, normalize_state(&1.state)))
  end

  defp normalize_issue(issue, repo) when is_map(issue) and is_binary(repo) do
    issue_number = issue["number"]
    state = issue["state"]

    if is_integer(issue_number) and issue_number > 0 and
         Enum.all?([issue["title"], state], &present_string?/1) do
      %Issue{
        id: Integer.to_string(issue_number),
        native_ref: native_ref(issue, repo),
        identifier: "GH-#{issue_number}",
        title: issue["title"],
        description: issue["body"],
        state: state,
        url: issue["html_url"],
        assignee_id: get_in(issue, ["assignee", "login"]),
        labels: extract_labels(issue),
        blocked_by: [],
        dispatchable: not Map.has_key?(issue, "pull_request"),
        created_at: parse_datetime(issue["created_at"]),
        updated_at: parse_datetime(issue["updated_at"])
      }
    end
  end

  defp normalize_issue(_issue, _repo), do: nil

  defp native_ref(issue, repo) do
    %{
      "id" => issue["id"],
      "node_id" => issue["node_id"],
      "number" => issue["number"],
      "repo" => repo
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      ref -> ref
    end
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_issue), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp validate_agent_lease(%{lane: lane, issue: %Issue{id: issue_id}, lease_token: token})
       when lane in [:individual, "individual"] and is_binary(token) do
    if Store.agent_lease_active?(issue_id, token),
      do: :ok,
      else: {:error, :stale_agent_lease}
  end

  defp validate_agent_lease(%{issue: %Issue{id: issue_id}, lane: lane, generation: generation, attempt: attempt} = context)
       when is_integer(generation) and is_integer(attempt) do
    lease_phase = Map.get(context, :lease_phase) || lane

    if Store.agent_lease_active?(issue_id, generation, to_string(lease_phase), attempt),
      do: :ok,
      else: {:error, :stale_agent_lease}
  end

  defp validate_agent_lease(_context), do: {:error, :missing_agent_lease}

  defp ensure_agent_repository(issue, settings) do
    repository = issue_repository(issue) || repository_from_issue_id(issue.id) || settings.repo

    with true <- same_repository?(repository, settings.repo),
         {:ok, _number} <- issue_number(issue) do
      :ok
    else
      false -> {:error, :github_issue_outside_task_repository}
      {:error, _reason} = error -> error
    end
  end

  defp issue_repository(issue) do
    ref = issue.native_ref || %{}
    map_value(ref, :repo) || map_value(ref, :repository)
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp repository_from_issue_id(id) when is_binary(id) do
    case String.split(id, "#", parts: 2) do
      [repository, _number] -> repository
      _ -> nil
    end
  end

  defp repository_from_issue_id(_id), do: nil

  defp same_repository?(repository, expected),
    do: is_binary(repository) and String.downcase(repository) == String.downcase(expected)

  defp issue_number(%Issue{native_ref: ref, id: id}) do
    case map_value(ref || %{}, :number) do
      number when is_integer(number) and number > 0 ->
        {:ok, number}

      _ ->
        parse_issue_number(issue_number_from_id(id))
    end
  end

  defp issue_number_from_id(id) when is_binary(id) do
    case String.split(id, "#", parts: 2) do
      [_repository, number] -> number
      [number] -> number
    end
  end

  defp issue_number_from_id(_id), do: nil

  defp agent_claim(issue, context, settings, request_fun) do
    marker = claim_marker(issue, context)
    body = claim_body(marker, "active")

    with {:ok, current_issue} <- current_issue(issue, settings, request_fun),
         :ok <- ensure_issue_open(current_issue),
         {:ok, evidence} <- upsert_agent_comment(issue, marker, "<!-- symphony:claim:end -->", body, settings, request_fun) do
      {:ok, %{"issue" => %{"id" => issue.id, "url" => current_issue["html_url"] || issue.url, "state" => current_issue["state"]}, "claim" => evidence}}
    end
  end

  defp agent_release_claim(issue, context, settings, request_fun) do
    marker = claim_marker(issue, context)
    body = claim_body(marker, "released")

    with {:ok, evidence} <- upsert_agent_comment(issue, marker, "<!-- symphony:claim:end -->", body, settings, request_fun) do
      {:ok, %{"issue" => issue_evidence(issue), "claim" => evidence}}
    end
  end

  defp agent_workpad(issue, arguments, settings, request_fun) do
    body = Map.get(arguments, "body")
    marker = "<!-- symphony:workpad:start -->"
    end_marker = "<!-- symphony:workpad:end -->"

    with body when is_binary(body) and byte_size(body) in 1..60_000 <- body,
         false <- String.contains?(body, [marker, end_marker]),
         content = workpad_body(body, marker, end_marker),
         {:ok, evidence} <- upsert_agent_comment(issue, marker, end_marker, content, settings, request_fun) do
      {:ok, %{"issue" => issue_evidence(issue), "comment" => evidence}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_github_workpad}
    end
  end

  defp workpad_body(body, marker, end_marker) do
    content = String.trim(body)
    content = if String.starts_with?(content, "## Codex Workpad"), do: content, else: "## Codex Workpad\n\n" <> content
    marker <> "\n" <> content <> "\n" <> end_marker
  end

  defp agent_handoff(issue, context, arguments, settings, request_fun) do
    report = normalize_report(arguments["report"])
    outcome = arguments["outcome"] || report["outcome"]
    report = Map.put(report, "outcome", outcome)
    agent_body = Map.get(arguments, "body")

    with :ok <- validate_agent_handoff(issue, context, outcome, report),
         :ok <- AgentReport.validate_body(agent_body, report),
         {:ok, current_issue} <- current_issue(issue, settings, request_fun),
         :ok <- ensure_issue_open(current_issue),
         {:ok, pull_request} <- maybe_upsert_agent_pull_request(issue, context, report, settings, request_fun),
         marker = report_marker(issue, context),
         body = AgentReport.comment_body(marker, agent_body),
         {:ok, comment} <- upsert_agent_comment(issue, marker, "<!-- symphony:report:end -->", body, settings, request_fun) do
      {:ok,
       %{
         "outcome" => outcome,
         "issue" => %{"id" => issue.id, "url" => current_issue["html_url"] || issue.url, "state" => current_issue["state"]},
         "comment" => comment,
         "pull_request" => pull_request,
         "sha" => report["sha"]
       }}
    end
  end

  defp validate_agent_handoff(issue, context, outcome, report) do
    lane = to_string(context.lane)

    with :ok <- validate_handoff_lane(lane),
         :ok <- validate_handoff_outcome(outcome),
         :ok <- validate_build_report_for_outcome(outcome, report, issue),
         :ok <- validate_handoff_reason(outcome, report) do
      validate_diagnostic_handoff(lane, outcome)
    end
  end

  defp validate_handoff_lane(lane) when lane in ["individual", "build", "diagnostic"], do: :ok
  defp validate_handoff_lane(_lane), do: {:error, :github_handoff_not_authorized_for_lane}

  defp validate_handoff_outcome(outcome) when outcome in ["ready", "blocked", "no_changes"], do: :ok
  defp validate_handoff_outcome(_outcome), do: {:error, :invalid_github_handoff_outcome}

  defp validate_build_report_for_outcome("ready", report, issue),
    do: if(valid_build_report?(report, issue), do: :ok, else: {:error, :invalid_github_build_report})

  defp validate_build_report_for_outcome(_outcome, _report, _issue), do: :ok

  defp validate_handoff_reason(outcome, report) when outcome in ["blocked", "no_changes"],
    do: if(is_binary(report["reason"]), do: :ok, else: {:error, :github_handoff_reason_required})

  defp validate_handoff_reason(_outcome, _report), do: :ok

  defp validate_diagnostic_handoff("diagnostic", "blocked"), do: :ok
  defp validate_diagnostic_handoff("diagnostic", _outcome), do: {:error, :invalid_github_diagnostic_handoff}
  defp validate_diagnostic_handoff(_lane, _outcome), do: :ok

  defp valid_build_report?(report, issue) do
    is_binary(report["summary"]) and is_binary(report["sha"]) and
      Regex.match?(~r/^[0-9a-fA-F]{40}$/, report["sha"]) and
      Enum.all?(["criteria", "changes", "checks", "risks"], &is_list(report[&1])) and
      PRBody.validate_agent_body(report["pull_request_body"], issue.id) == :ok
  end

  defp current_issue(issue, settings, request_fun) do
    with {:ok, number} <- issue_number(issue),
         {:ok, %{} = current} <-
           request_with_settings(
             "GET",
             repository_issue_path(settings, number),
             %{},
             nil,
             settings,
             request_fun,
             true
           ) do
      {:ok, current}
    else
      {:ok, :not_found} -> {:error, :github_issue_not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :github_issue_response_invalid}
    end
  end

  defp ensure_issue_open(%{"state" => "open"}), do: :ok
  defp ensure_issue_open(_issue), do: {:error, :github_issue_closed_by_human}

  defp maybe_upsert_agent_pull_request(_issue, _context, %{"outcome" => outcome}, _settings, _request_fun)
       when outcome != "ready",
       do: {:ok, nil}

  defp maybe_upsert_agent_pull_request(issue, context, report, settings, request_fun) do
    task = Map.get(context, :task) || %{}
    branch = task["branch"] || issue.branch_name

    with branch when is_binary(branch) and branch != "" <- branch,
         {:ok, base} <- agent_pull_request_base(task, settings, request_fun),
         :ok <- validate_pushed_sha(branch, report["sha"], settings, request_fun),
         {:ok, existing} <- find_agent_pull_request(branch, base, settings, request_fun),
         {:ok, _} <- create_or_update_agent_pull_request(existing, issue, branch, base, report, settings, request_fun),
         {:ok, verified} <- find_agent_pull_request(branch, base, settings, request_fun),
         :ok <- verify_agent_pull_request(verified, report["sha"], base) do
      {:ok, pull_request_evidence(verified)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_pull_request_handoff_failed}
    end
  end

  defp agent_pull_request_base(task, settings, request_fun) do
    case task["base_branch"] || settings.base_branch do
      base when is_binary(base) and base != "" ->
        {:ok, base}

      _ ->
        with {:ok, %{"default_branch" => base}} <-
               request_with_settings("GET", "/repos/#{settings.repo}", %{}, nil, settings, request_fun, false),
             true <- is_binary(base) and base != "" do
          {:ok, base}
        else
          {:error, _reason} = error -> error
          _ -> {:error, :github_default_branch_missing}
        end
    end
  end

  defp validate_pushed_sha(branch, sha, settings, request_fun) do
    path = "/repos/#{settings.repo}/git/ref/heads/#{URI.encode(branch, &URI.char_unreserved?/1)}"

    with true <- is_binary(sha) and Regex.match?(~r/^[0-9a-fA-F]{40}$/, sha),
         {:ok, data} <- request_with_settings("GET", path, %{}, nil, settings, request_fun, false),
         ^sha <- get_in(data, ["object", "sha"]) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_pushed_sha_not_verified}
    end
  end

  defp find_agent_pull_request(branch, base, settings, request_fun) do
    {owner, _name} = split_repository(settings.repo)
    params = %{"head" => "#{owner}:#{branch}", "base" => base, "state" => "all", "per_page" => @page_size}

    with {:ok, pull_requests} <- request_with_settings("GET", "/repos/#{settings.repo}/pulls", params, nil, settings, request_fun, false),
         true <- is_list(pull_requests) do
      {:ok, Enum.find(pull_requests, &(get_in(&1, ["head", "ref"]) == branch and get_in(&1, ["base", "ref"]) == base))}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_pull_request_list_invalid}
    end
  end

  defp create_or_update_agent_pull_request(nil, issue, branch, base, report, settings, request_fun) do
    title = issue.title || issue.identifier
    body = delivery_body(report)
    request_body = %{"title" => title, "head" => branch, "base" => base, "body" => body, "draft" => true}

    case request_with_settings("POST", "/repos/#{settings.repo}/pulls", %{}, request_body, settings, request_fun, false) do
      {:ok, %{"number" => _number}} ->
        {:ok, :created}

      {:error, _reason} = error ->
        case find_agent_pull_request(branch, base, settings, request_fun) do
          {:ok, %{} = pull_request} -> {:ok, pull_request}
          _ -> error
        end

      _ ->
        {:error, :github_pull_request_create_failed}
    end
  end

  defp create_or_update_agent_pull_request(pull_request, issue, _branch, base, report, settings, request_fun) do
    with :ok <- verify_agent_pull_request(pull_request, report["sha"], base),
         :ok <- update_agent_pull_request_body(pull_request, issue, report, settings, request_fun) do
      {:ok, pull_request}
    end
  end

  defp update_agent_pull_request_body(pull_request, _issue, report, settings, request_fun) do
    body = pull_request["body"] || ""

    case replace_owned_block(body, "<!-- symphony:delivery:start -->", "<!-- symphony:delivery:end -->", delivery_body(report)) do
      {:ok, updated} when updated == body ->
        :ok

      {:ok, updated} ->
        with {:ok, _} <-
               request_with_settings(
                 "PATCH",
                 "/repos/#{settings.repo}/pulls/#{pull_request["number"]}",
                 %{},
                 %{"body" => updated},
                 settings,
                 request_fun,
                 false
               ),
             {:ok, %{} = verified} <-
               find_agent_pull_request(
                 pull_request["head"]["ref"],
                 pull_request["base"]["ref"],
                 settings,
                 request_fun
               ),
             true <- verified["body"] == updated do
          :ok
        else
          {:error, _reason} = error -> error
          _ -> {:error, :github_pull_request_body_update_not_verified}
        end

      {:error, :agent_block_missing} ->
        :ok
    end
  end

  defp verify_agent_pull_request(nil, _sha, _base), do: {:error, :github_pull_request_not_found}

  defp verify_agent_pull_request(pull_request, sha, base) do
    cond do
      pull_request["state"] != "open" -> {:error, :github_pull_request_not_open}
      pull_request["draft"] != true -> {:error, :github_pull_request_not_draft}
      get_in(pull_request, ["base", "ref"]) != base -> {:error, :github_pull_request_base_mismatch}
      get_in(pull_request, ["head", "sha"]) != sha -> {:error, :github_pull_request_head_sha_mismatch}
      true -> :ok
    end
  end

  defp pull_request_evidence(pull_request) do
    %{
      "id" => to_string(pull_request["id"] || pull_request["node_id"] || pull_request["number"]),
      "number" => pull_request["number"],
      "url" => pull_request["html_url"],
      "head_sha" => get_in(pull_request, ["head", "sha"]),
      "base" => get_in(pull_request, ["base", "ref"]),
      "draft" => pull_request["draft"],
      "merged" => not is_nil(pull_request["merged_at"])
    }
  end

  defp delivery_body(report), do: PRBody.delivery_block(report["pull_request_body"])

  defp upsert_agent_comment(issue, marker, end_marker, body, settings, request_fun) do
    with {:ok, number} <- issue_number(issue),
         {:ok, login} <- current_login(settings, request_fun),
         {:ok, existing} <- find_agent_comment(number, marker, settings, request_fun, 1) do
      case existing do
        nil -> create_agent_comment(number, login, marker, body, settings, request_fun)
        comment -> update_agent_comment(number, login, marker, end_marker, body, comment, settings, request_fun)
      end
    end
  end

  defp create_agent_comment(number, login, marker, body, settings, request_fun) do
    path = repository_issue_path(settings, number) <> "/comments"

    case request_with_settings("POST", path, %{}, %{"body" => body}, settings, request_fun, false) do
      {:ok, _created} ->
        verify_agent_comment(number, login, marker, body, settings, request_fun)

      {:error, reason} ->
        case verify_agent_comment(number, login, marker, body, settings, request_fun) do
          {:ok, _evidence} = found -> found
          _ -> {:error, reason}
        end
    end
  end

  defp update_agent_comment(number, login, marker, end_marker, replacement, comment, settings, request_fun) do
    if get_in(comment, ["user", "login"]) == login do
      with {:ok, body} <- replace_owned_block(comment["body"] || "", marker, end_marker, replacement),
           :ok <- patch_agent_comment(number, comment, marker, body, settings, request_fun) do
        verify_agent_comment(number, login, marker, body, settings, request_fun)
      end
    else
      {:error, :github_agent_comment_not_owned}
    end
  end

  defp patch_agent_comment(number, comment, marker, body, settings, request_fun) do
    if comment["body"] == body do
      :ok
    else
      path = "/repos/#{settings.repo}/issues/comments/#{comment["id"]}"

      case request_with_settings("PATCH", path, %{}, %{"body" => body}, settings, request_fun, false) do
        {:ok, _updated} ->
          :ok

        {:error, reason} ->
          recover_agent_comment_update(number, marker, body, reason, settings, request_fun)
      end
    end
  end

  defp recover_agent_comment_update(number, marker, body, reason, settings, request_fun) do
    case find_agent_comment(number, marker, settings, request_fun, 1) do
      {:ok, %{"body" => ^body}} -> :ok
      _ -> {:error, reason}
    end
  end

  defp verify_agent_comment(number, login, marker, body, settings, request_fun) do
    with {:ok, %{} = comment} <- find_agent_comment(number, marker, settings, request_fun, 1),
         true <- get_in(comment, ["user", "login"]) == login,
         true <- comment["body"] == body do
      {:ok, comment_evidence(comment, marker)}
    else
      false -> {:error, :github_agent_comment_not_verified}
      {:error, _reason} = error -> error
      _ -> {:error, :github_agent_comment_not_verified}
    end
  end

  defp find_agent_comment(number, marker, settings, request_fun, page) do
    path = repository_issue_path(settings, number) <> "/comments"

    with {:ok, comments} <-
           request_with_settings(
             "GET",
             path,
             %{"per_page" => @page_size, "page" => page},
             nil,
             settings,
             request_fun,
             false
           ),
         true <- is_list(comments) do
      case Enum.find(comments, &String.contains?(&1["body"] || "", marker)) do
        nil when length(comments) == @page_size -> find_agent_comment(number, marker, settings, request_fun, page + 1)
        comment -> {:ok, comment}
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_issue_comments_invalid}
    end
  end

  defp current_login(settings, request_fun) do
    with {:ok, %{"login" => login}} <- request_with_settings("GET", "/user", %{}, nil, settings, request_fun, false),
         true <- is_binary(login) and login != "" do
      {:ok, login}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_agent_identity_missing}
    end
  end

  defp comment_evidence(comment, marker) do
    %{"id" => to_string(comment["id"]), "url" => comment["html_url"], "marker" => marker}
  end

  defp issue_evidence(issue),
    do: %{"id" => issue.id, "url" => issue.url, "state" => issue.state || "open"}

  defp claim_marker(issue, context),
    do: "<!-- symphony:claim:start:#{issue.id}:#{context[:generation] || 0}:#{context[:lane]} -->"

  defp claim_body(marker, state),
    do: marker <> "\nSymphony claim #{state}.\n<!-- symphony:claim:end -->"

  defp report_marker(issue, context),
    do: "<!-- symphony:report:start:#{issue.id}:#{context[:generation] || 0}:#{context[:lane]} -->"

  defp replace_owned_block(current, start_marker, end_marker, replacement) do
    with {start, _} <- :binary.match(current, start_marker),
         {finish, length} <- :binary.match(current, end_marker, scope: {start, byte_size(current) - start}) do
      prefix = binary_part(current, 0, start)
      suffix_start = finish + length
      suffix = binary_part(current, suffix_start, byte_size(current) - suffix_start)
      {:ok, prefix <> replacement <> suffix}
    else
      :nomatch -> {:error, :agent_block_missing}
    end
  end

  defp create_follow_up_issue(issue, context, arguments, settings, request_fun) do
    title = normalize_string(arguments["title"])
    body = normalize_string(arguments["body"])
    digest = :crypto.hash(:sha256, (title || "") <> "\n" <> (body || "")) |> Base.encode16(case: :lower)
    marker = "<!-- symphony:follow-up:#{issue.id}:#{context[:generation] || 0}:#{context[:lane]}:#{digest} -->"

    with title when is_binary(title) and byte_size(title) <= 256 <- title,
         body when is_binary(body) and byte_size(body) <= 60_000 <- body,
         {:ok, _number} <- issue_number(issue),
         {:ok, existing} <- find_follow_up_issue(marker, settings, request_fun),
         {:ok, follow_up} <-
           find_or_create_follow_up_issue(existing, issue, title, body, marker, settings, request_fun),
         :ok <- link_follow_up_issue(issue, follow_up, settings, request_fun) do
      {:ok, %{"id" => "#{settings.repo}##{follow_up["number"]}", "number" => follow_up["number"], "url" => follow_up["html_url"], "parent" => issue.id, "linked" => true, "marker" => marker}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_follow_up_issue}
    end
  end

  defp find_or_create_follow_up_issue(%{} = existing, _issue, _title, _body, _marker, _settings, _request_fun),
    do: {:ok, existing}

  defp find_or_create_follow_up_issue(nil, issue, title, body, marker, settings, request_fun),
    do: create_follow_up_issue_remote(issue, title, body, marker, settings, request_fun)

  defp find_follow_up_issue(marker, settings, request_fun) do
    query = "repo:#{settings.repo} in:body #{marker}"

    with {:ok, %{"items" => items}} <-
           request_with_settings(
             "GET",
             "/search/issues",
             %{"q" => query, "per_page" => 10},
             nil,
             settings,
             request_fun,
             false
           ),
         true <- is_list(items) do
      {:ok, Enum.find(items, &String.contains?(&1["body"] || "", marker))}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_follow_up_search_failed}
    end
  end

  defp create_follow_up_issue_remote(issue, title, body, marker, settings, request_fun) do
    request_body = %{"title" => title, "body" => body <> "\n\nParent: #{issue.url}\n\n#{marker}"}
    result = request_with_settings("POST", "/repos/#{settings.repo}/issues", %{}, request_body, settings, request_fun, false)

    case result do
      {:ok, %{"number" => number} = follow_up} when is_integer(number) ->
        {:ok, follow_up}

      {:error, _reason} = error ->
        case find_follow_up_issue(marker, settings, request_fun) do
          {:ok, %{} = found} -> {:ok, found}
          _ -> error
        end

      _ ->
        {:error, :github_follow_up_create_failed}
    end
  end

  defp link_follow_up_issue(parent, child, settings, request_fun) do
    with {:ok, parent_number} <- issue_number(parent),
         child_id when is_integer(child_id) <- child["id"],
         path = repository_issue_path(settings, parent_number) <> "/sub_issues",
         {:ok, existing} <- request_with_settings("GET", path, %{"per_page" => @page_size}, nil, settings, request_fun, false),
         true <- is_list(existing) do
      if Enum.any?(existing, &(to_string(&1["id"]) == to_string(child_id))),
        do: :ok,
        else: create_follow_up_link(path, child_id, settings, request_fun)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_follow_up_link_failed}
    end
  end

  defp create_follow_up_link(path, child_id, settings, request_fun) do
    result = request_with_settings("POST", path, %{}, %{"sub_issue_id" => child_id}, settings, request_fun, false)

    case result do
      {:ok, _} -> verify_follow_up_link(path, child_id, settings, request_fun)
      {:error, reason} -> recover_follow_up_link(path, child_id, reason, settings, request_fun)
    end
  end

  defp recover_follow_up_link(path, child_id, reason, settings, request_fun) do
    if verify_follow_up_link(path, child_id, settings, request_fun) == :ok,
      do: :ok,
      else: {:error, reason}
  end

  defp verify_follow_up_link(path, child_id, settings, request_fun) do
    with {:ok, issues} <- request_with_settings("GET", path, %{"per_page" => @page_size}, nil, settings, request_fun, false),
         true <- is_list(issues) and Enum.any?(issues, &(to_string(&1["id"]) == to_string(child_id))) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_follow_up_link_not_verified}
    end
  end

  defp request_with_settings(method, path, params, body, settings, request_fun, allow_not_found) do
    case request_fun.(method, path, params, body, settings) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %{status: 404}} when allow_not_found ->
        {:ok, :not_found}

      {:ok, %{status: status}} when is_integer(status) ->
        Logger.error("GitHub API request failed status=#{status} method=#{method} path=#{path}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_unknown_payload}
    end
  end

  defp perform_request(method, path, params, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      request_opts = [
        method: request_method,
        url: settings.api_url <> path,
        headers: github_headers(settings.token),
        params: params,
        connect_options: [timeout: 30_000]
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(request_opts) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    api_url = provider["api_url"] || @default_api_url
    repo = resolve_setting(provider["repo"], System.get_env("GITHUB_REPO"))
    token = resolve_setting(provider["token"], System.get_env("GITHUB_TOKEN"))
    base_branch = normalize_string(provider["base_branch"])
    merge_policy = provider["merge_policy"] || "human"

    cond do
      not valid_api_url?(api_url) ->
        {:error, :invalid_github_api_url}

      not present_string?(repo) ->
        {:error, :missing_github_repo}

      not valid_repo?(repo) ->
        {:error, :invalid_github_repo}

      not present_string?(token) ->
        {:error, :missing_github_token}

      merge_policy not in ["human", "auto"] ->
        {:error, :invalid_merge_policy}

      true ->
        {:ok,
         %{
           api_url: String.trim_trailing(api_url, "/"),
           repo: repo,
           token: token,
           base_branch: base_branch,
           merge_policy: merge_policy
         }}
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || fallback)
    else
      nil
    end
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_report(report) when is_map(report),
    do: Map.new(report, fn {key, value} -> {to_string(key), value} end)

  defp normalize_report(_report), do: %{}

  defp split_repository(repository) do
    case String.split(repository, "/", parts: 2) do
      [owner, name] -> {owner, name}
      _ -> {"", ""}
    end
  end

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name when is_binary(env_name) -> if valid_env_name?(env_name), do: [env_name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_api_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_api_url?(_value), do: false
  defp valid_repo?(repo) when is_binary(repo), do: String.match?(repo, ~r/^[^\s\/]+\/[^\s\/]+$/)
  defp valid_repo?(_repo), do: false

  defp repository_issues_path(settings), do: "/repos/#{encoded_repo(settings.repo)}/issues"

  defp repository_issue_path(settings, issue_number),
    do: "#{repository_issues_path(settings)}/#{issue_number}"

  defp encoded_repo(repo) do
    repo
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp github_headers(token) do
    [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{token}"},
      {"X-GitHub-Api-Version", @api_version},
      {"User-Agent", @user_agent}
    ]
  end

  defp github_state_query(states) do
    has_open? = MapSet.member?(states, "open")
    has_closed? = MapSet.member?(states, "closed")

    cond do
      has_open? and has_closed? -> "all"
      has_open? -> "open"
      has_closed? -> "closed"
      true -> nil
    end
  end

  defp parse_issue_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp parse_issue_number(_value), do: {:error, :invalid_github_issue_id}

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PATCH"), do: {:ok, :patch}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_github_method}

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
