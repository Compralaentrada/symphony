defmodule SymphonyElixir.GitHub.Projects.Client do
  @moduledoc """
  GitHub Projects v2 GraphQL client for issue-backed work items.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @default_graphql_url "https://api.github.com/graphql"
  @status_field "Status"
  @statuses %{
    backlog: "Backlog",
    ready: "Ready",
    building: "Building",
    qa: "QA",
    review: "Review",
    human_review: "Human Review",
    blocked: "Blocked",
    done: "Done",
    dropped: "Dropped"
  }
  @project_query """
  query SymphonyProject($owner: String!, $number: Int!, $after: String) {
    user(login: $owner) { projectV2(number: $number) { ...SymphonyProjectFields } }
    organization(login: $owner) { projectV2(number: $number) { ...SymphonyProjectFields } }
  }

  fragment SymphonyProjectFields on ProjectV2 {
    id
    fields(first: 100) {
      nodes {
        __typename
        ... on ProjectV2SingleSelectField { id name options { id name } }
      }
    }
    items(first: 100, after: $after) {
      nodes {
        id
        content {
          __typename
          ... on Issue {
            id number title body state stateReason url createdAt updatedAt
            repository { nameWithOwner }
            labels(first: 100) { nodes { name } }
            blockedBy(first: 100) {
              nodes { number state repository { nameWithOwner } }
              pageInfo { hasNextPage endCursor }
              totalCount
            }
          }
        }
        fieldValues(first: 100) {
          nodes {
            __typename
            ... on ProjectV2ItemFieldSingleSelectValue {
              name
              field { ... on ProjectV2SingleSelectField { name } }
            }
          }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @issue_blockers_query """
  query SymphonyIssueBlockers($issueId: ID!, $after: String) {
    node(id: $issueId) {
      ... on Issue {
        blockedBy(first: 100, after: $after) {
          nodes { number state repository { nameWithOwner } }
          pageInfo { hasNextPage endCursor }
          totalCount
        }
      }
    }
  }
  """

  @status_mutation """
  mutation SymphonySetProjectStatus(
    $projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!
  ) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId,
      itemId: $itemId,
      fieldId: $fieldId,
      value: { singleSelectOptionId: $optionId }
    }) {
      projectV2Item { id }
    }
  }
  """

  @comment_mutation """
  mutation SymphonyAddIssueComment($subjectId: ID!, $body: String!) {
    addComment(input: { subjectId: $subjectId, body: $body }) {
      commentEdge { node { id } }
    }
  }
  """

  @delivery_query """
  query SymphonyPipelineDelivery($owner: String!, $name: String!, $branch: String!) {
    repository(owner: $owner, name: $name) {
      ref(qualifiedName: $branch) { name target { ... on Commit { oid } } }
    }
  }
  """

  @repository_query """
  query SymphonyPipelineRepository($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) { id }
  }
  """

  @pull_request_query """
  query SymphonyPipelinePullRequest($owner: String!, $name: String!, $branch: String!, $base: String!) {
    repository(owner: $owner, name: $name) {
      pullRequests(first: 100, states: [OPEN, CLOSED, MERGED], headRefName: $branch, baseRefName: $base) {
        nodes { id number url state isDraft mergedAt baseRefName headRefName headRefOid body }
      }
    }
  }
  """

  @create_pull_request_mutation """
  mutation SymphonyCreatePipelinePullRequest($input: CreatePullRequestInput!) {
    createPullRequest(input: $input) { pullRequest { id number url state isDraft mergedAt baseRefName headRefName headRefOid body } }
  }
  """

  @update_pull_request_body_mutation """
  mutation SymphonyUpdatePipelinePullRequestBody($pullRequestId: ID!, $body: String!) {
    updatePullRequest(input: { pullRequestId: $pullRequestId, body: $body }) {
      pullRequest { id number url state isDraft mergedAt baseRefName headRefName headRefOid body }
    }
  }
  """

  @draft_mutation """
  mutation SymphonyConvertPipelinePullRequestToDraft($pullRequestId: ID!) {
    convertPullRequestToDraft(input: { pullRequestId: $pullRequestId }) {
      pullRequest { id number url state isDraft mergedAt baseRefName headRefName headRefOid }
    }
  }
  """

  @ready_mutation """
  mutation SymphonyMarkPipelinePullRequestReady($pullRequestId: ID!) {
    markPullRequestReadyForReview(input: { pullRequestId: $pullRequestId }) {
      pullRequest { id number url state isDraft mergedAt baseRefName headRefName headRefOid }
    }
  }
  """

  @comments_query """
  query SymphonyPipelineReportComments($owner: String!, $name: String!, $number: Int!, $after: String) {
    repository(owner: $owner, name: $name) {
      issue(number: $number) { comments(first: 100, after: $after) { nodes { body } pageInfo { hasNextPage endCursor } } }
    }
  }
  """

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    case settings(tracker_settings) do
      {:ok, _settings} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    (["GITHUB_TOKEN", "GH_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_ENTERPRISE_TOKEN"] ++
       env_reference_names(provider["token"]))
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    fetch_issues_by_states(states, Config.settings!().tracker, &perform_request/3)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids) when is_list(ids) do
    fetch_issues_by_ids(ids, Config.settings!().tracker, &perform_request/3)
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, tracker_settings, request_fun)
      when is_list(states) and is_map(tracker_settings) and is_function(request_fun, 3) do
    fetch_issues_by_states(states, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(ids, tracker_settings, request_fun)
      when is_list(ids) and is_map(tracker_settings) and is_function(request_fun, 3) do
    fetch_issues_by_ids(ids, tracker_settings, request_fun)
  end

  @doc false
  @spec update_issue_status_for_test(Issue.t(), String.t(), String.t(), map(), function()) ::
          :ok | {:error, term()}
  def update_issue_status_for_test(issue, status, reason, tracker_settings, request_fun)
      when is_struct(issue, Issue) and is_binary(status) and is_binary(reason) and
             is_map(tracker_settings) and is_function(request_fun, 3) do
    with {:ok, settings} <- settings(tracker_settings),
         :ok <- set_item_status(issue.native_ref, status, settings, request_fun) do
      if normalize_state(status) == "blocked" do
        add_issue_comment(issue.native_ref, reason, settings, request_fun)
      else
        :ok
      end
    end
  end

  @doc false
  @spec complete_issue_for_test(Issue.t(), map(), function()) :: :ok | {:error, term()}
  def complete_issue_for_test(issue, tracker_settings, request_fun)
      when is_struct(issue, Issue) and is_map(tracker_settings) and is_function(request_fun, 3) do
    complete_issue(issue, tracker_settings, request_fun)
  end

  @spec claim_issue(Issue.t()) :: :ok | {:error, term()}
  def claim_issue(issue) do
    update_issue_status(issue, :building, nil, Config.settings!().tracker, &perform_request/3)
  end

  @spec complete_issue(Issue.t()) :: :ok | {:error, term()}
  def complete_issue(issue) do
    complete_issue(issue, Config.settings!().tracker, &perform_request/3)
  end

  @spec block_issue(Issue.t(), String.t()) :: :ok | {:error, term()}
  def block_issue(issue, reason) when is_binary(reason) do
    update_issue_status(issue, :blocked, reason, Config.settings!().tracker, &perform_request/3)
  end

  @spec set_pipeline_status(Issue.t(), atom(), String.t() | nil) :: :ok | {:error, term()}
  def set_pipeline_status(issue, status, _reason \\ nil) do
    with {:ok, settings} <- settings(Config.settings!().tracker),
         ref when is_map(ref) <- issue.native_ref,
         status when is_binary(status) <- Map.get(settings.statuses, status),
         :ok <- set_item_status(ref, status, settings, &perform_request/3) do
      :ok
    else
      nil -> {:error, {:github_projects_api_error, "Project item reference is missing."}}
      {:error, _reason} = error -> error
      _other -> {:error, {:github_projects_configuration_error, "Pipeline status is not configured."}}
    end
  end

  @spec validate_pipeline_delivery(Issue.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def validate_pipeline_delivery(issue, branch, sha)
      when is_binary(branch) and is_binary(sha) do
    with {:ok, settings} <- settings(Config.settings!().tracker),
         {:ok, data} <- graphql(&perform_request/3, @delivery_query, delivery_variables(issue, branch), settings),
         %{"target" => %{"oid" => ^sha}} <- get_in(data, ["repository", "ref"]) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:github_projects_api_error, "The pushed branch does not contain the reported SHA in the configured repository."}}
    end
  end

  @spec upsert_pull_request(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def upsert_pull_request(issue, attrs) do
    upsert_pull_request(issue, attrs, Config.settings!().tracker, &perform_request/3)
  end

  @doc false
  @spec upsert_pull_request_for_test(Issue.t(), map(), map(), function()) :: {:ok, map()} | {:error, term()}
  def upsert_pull_request_for_test(issue, attrs, tracker_settings, request_fun)
      when is_struct(issue, Issue) and is_map(attrs) and is_map(tracker_settings) and is_function(request_fun, 3) do
    upsert_pull_request(issue, attrs, tracker_settings, request_fun)
  end

  defp upsert_pull_request(issue, attrs, tracker_settings, request_fun) do
    with {:ok, settings} <- settings(tracker_settings),
         {:ok, repository} <- repository_for_issue(issue),
         {:ok, existing} <- find_pull_request(issue, attrs.branch, attrs.base, settings, request_fun) do
      case existing do
        %{} = pr -> update_pull_request_body(pr, Map.get(attrs, :body), settings, request_fun)
        nil -> create_pull_request(issue, repository, attrs, settings, request_fun)
      end
    end
  end

  @spec set_pull_request_stage(Issue.t(), integer(), :draft | :ready) :: {:ok, map()} | {:error, term()}
  def set_pull_request_stage(issue, _number, stage) when stage in [:draft, :ready] do
    with {:ok, settings} <- settings(Config.settings!().tracker),
         {:ok, %{} = pr} <- pull_request(issue, settings, &perform_request/3) do
      update_pull_request_stage(pr, stage, settings)
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:github_projects_api_error, "Unable to update the pull request review stage."}}
    end
  end

  defp update_pull_request_stage(%{draft: draft} = pr, stage, _settings) when draft == (stage == :draft),
    do: {:ok, pr}

  defp update_pull_request_stage(pr, stage, settings) do
    {mutation, result_key} = pull_request_stage_mutation(stage)

    case graphql(&perform_request/3, mutation, %{"pullRequestId" => pr.id}, settings) do
      {:ok, data} ->
        case get_in(data, [result_key, "pullRequest"]) do
          %{} = updated -> {:ok, normalize_pull_request(updated)}
          _ -> {:error, {:github_projects_api_error, "Unable to update the pull request review stage."}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp pull_request_stage_mutation(:draft), do: {@draft_mutation, "convertPullRequestToDraft"}
  defp pull_request_stage_mutation(:ready), do: {@ready_mutation, "markPullRequestReadyForReview"}

  @spec pull_request(Issue.t()) :: {:ok, map() | nil} | {:error, term()}
  def pull_request(issue) do
    with {:ok, settings} <- settings(Config.settings!().tracker) do
      pull_request(issue, settings, &perform_request/3)
    end
  end

  @doc false
  @spec pull_request_for_test(Issue.t(), map(), function()) :: {:ok, map() | nil} | {:error, term()}
  def pull_request_for_test(issue, tracker_settings, request_fun)
      when is_struct(issue, Issue) and is_map(tracker_settings) and is_function(request_fun, 3) do
    with {:ok, settings} <- settings(tracker_settings) do
      pull_request(issue, settings, request_fun)
    end
  end

  @spec publish_phase_report(Issue.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def publish_phase_report(issue, marker, body, _phase) do
    with {:ok, settings} <- settings(Config.settings!().tracker),
         {:ok, issue_ref} <- issue_repository_and_number(issue),
         {:ok, exists?} <- issue_comment_has_marker?(issue_ref, marker, settings, &perform_request/3, nil) do
      if exists?, do: :ok, else: create_phase_report(issue, body, settings)
    end
  end

  defp create_phase_report(issue, body, settings) do
    case ref_value(issue.native_ref, :issue_node_id) do
      subject_id when is_binary(subject_id) ->
        case graphql(&perform_request/3, @comment_mutation, %{"subjectId" => subject_id, "body" => body}, settings) do
          {:ok, _} -> :ok
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, {:github_projects_api_error, "Linked GitHub Issue has no node ID for the phase report."}}
    end
  end

  defp fetch_issues_by_states(states, tracker_settings, request_fun) do
    requested = MapSet.new(states, &normalize_state/1)

    with {:ok, settings} <- settings(tracker_settings),
         {:ok, metadata, items} <- project_items(settings, request_fun),
         {:ok, issues} <- normalize_items(items, metadata, settings, request_fun) do
      issues
      |> Enum.filter(&requested_state?(&1, requested))
      |> then(&{:ok, &1})
    end
  end

  defp requested_state?(issue, requested) do
    normalized = normalize_state(issue.state)

    if normalized == "closed" do
      MapSet.member?(requested, "closed") or
        MapSet.member?(requested, normalize_state(Map.get(issue.native_ref, :project_status)))
    else
      MapSet.member?(requested, normalized)
    end
  end

  defp fetch_issues_by_ids(ids, tracker_settings, request_fun) do
    requested_ids = MapSet.new(ids)

    if MapSet.size(requested_ids) == 0 do
      {:ok, []}
    else
      with {:ok, settings} <- settings(tracker_settings),
           {:ok, metadata, items} <- project_items(settings, request_fun),
           {:ok, issues} <- normalize_items(items, metadata, settings, request_fun) do
        {:ok, Enum.filter(issues, &MapSet.member?(requested_ids, &1.id))}
      end
    end
  end

  defp project_items(settings, request_fun) do
    with {:ok, project} <- fetch_project(settings, request_fun, nil),
         {:ok, metadata} <- project_metadata(project, settings),
         {:ok, items} <- fetch_remaining_items(project, settings, request_fun, metadata, []) do
      {:ok, metadata, items}
    end
  end

  defp fetch_project(settings, request_fun, cursor) do
    variables = %{
      "owner" => settings.owner,
      "number" => settings.project_number,
      "after" => cursor
    }

    with {:ok, data} <- graphql(request_fun, @project_query, variables, settings),
         project when is_map(project) <- project_from_data(data) do
      {:ok, project}
    else
      nil ->
        {:error, {:github_projects_permission_error, "Project not found or inaccessible. Confirm the owner, project number, and token access."}}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, {:github_projects_api_error, "GitHub returned an invalid Project response."}}
    end
  end

  defp fetch_remaining_items(project, settings, request_fun, metadata, acc) do
    connection = project["items"] || %{}
    nodes = connection["nodes"] || []
    acc = acc ++ nodes
    page_info = connection["pageInfo"] || %{}

    if page_info["hasNextPage"] do
      with {:ok, next_project} <- fetch_project(settings, request_fun, page_info["endCursor"]) do
        fetch_remaining_items(next_project, settings, request_fun, metadata, acc)
      end
    else
      {:ok, acc}
    end
  end

  defp project_from_data(data) do
    get_in(data, ["user", "projectV2"]) || get_in(data, ["organization", "projectV2"])
  end

  defp project_metadata(project, settings) do
    fields = get_in(project, ["fields", "nodes"]) || []

    case Enum.find(fields, fn field -> field["__typename"] == "ProjectV2SingleSelectField" and field["name"] == settings.status_field end) do
      nil ->
        {:error, {:github_projects_configuration_error, "Project status field #{inspect(settings.status_field)} was not found or is not single-select."}}

      field ->
        options = field["options"] || []
        option_ids = Map.new(options, fn option -> {option["name"], option["id"]} end)
        missing = Enum.reject(Map.values(settings.statuses), &Map.has_key?(option_ids, &1))

        if missing == [] do
          {:ok,
           %{
             project_id: project["id"],
             status_field_id: field["id"],
             status_option_ids: option_ids
           }}
        else
          {:error, {:github_projects_configuration_error, "Project status field #{inspect(settings.status_field)} is missing canonical options: #{Enum.join(missing, ", ")}."}}
        end
    end
  end

  defp normalize_items(items, metadata, settings, request_fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, issues} ->
      case normalize_item(item, metadata, settings, request_fun) do
        {:ok, nil} -> {:cont, {:ok, issues}}
        {:ok, %Issue{} = issue} -> {:cont, {:ok, [issue | issues]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_item(item, metadata, settings, request_fun) do
    case item["content"] do
      %{"__typename" => "Issue"} ->
        normalize_linked_issue(item, metadata, settings, request_fun)

      _ ->
        {:ok, nil}
    end
  end

  defp normalize_linked_issue(item, metadata, settings, request_fun) do
    content = item["content"]

    with {:ok, blockers} <- issue_blockers(content, settings, request_fun) do
      normalize_linked_issue(item, metadata, settings, request_fun, blockers)
    end
  end

  defp normalize_linked_issue(item, metadata, settings, request_fun, blockers) do
    content = item["content"]
    status = item_status(item, settings.status_field)
    repository = get_in(content, ["repository", "nameWithOwner"])
    profile = Map.get(settings.repositories, normalize_repository(repository))

    cond do
      normalize_state(content["state"]) == "closed" ->
        {:ok, normalize_issue(item, metadata, settings, profile, "closed", status, blockers)}

      is_nil(status) ->
        {:ok, nil}

      is_nil(profile) and status_in?(status, [settings.statuses.ready, settings.statuses.building]) ->
        with :ok <- maybe_block_unconfigured(item, status, settings, metadata, request_fun) do
          {:ok, nil}
        end

      true ->
        {:ok, normalize_issue(item, metadata, settings, profile, status, status, blockers)}
    end
  end

  defp normalize_issue(item, metadata, settings, profile, state, project_status, blockers) do
    content = item["content"]
    repository = get_in(content, ["repository", "nameWithOwner"])
    number = content["number"]
    id = "#{repository}##{number}"

    dispatch_status? =
      status_in?(project_status, [
        settings.statuses.ready,
        settings.statuses.building,
        settings.statuses.qa,
        settings.statuses.review,
        settings.statuses.human_review
      ])

    native_ref = %{
      project_item_id: item["id"],
      project_id: metadata.project_id,
      status_field_id: metadata.status_field_id,
      status_option_ids: metadata.status_option_ids,
      project_status: project_status,
      issue_node_id: content["id"],
      issue_state: content["state"],
      issue_state_reason: content["stateReason"],
      repository: repository,
      base_branch: profile && profile.base_branch,
      prepare_command: profile && profile.prepare_command,
      required_checks: profile && profile.required_checks
    }

    %Issue{
      id: id,
      native_ref: native_ref,
      identifier: id,
      title: content["title"],
      description: content["body"],
      branch_name: work_branch(repository, number),
      state: state,
      url: content["url"],
      labels: extract_labels(content),
      dispatchable: not is_nil(profile) and dispatch_status? and state != "closed",
      requeueable: state != "closed" and not is_nil(profile) and status_in?(project_status, [settings.statuses.ready]),
      tracker_blocked: state != "closed" and status_in?(project_status, [settings.statuses.blocked]),
      blocked_by: blockers,
      created_at: parse_datetime(content["createdAt"]),
      updated_at: parse_datetime(content["updatedAt"])
    }
  end

  defp issue_blockers(content, settings, request_fun) do
    with {:ok, blockers, page_info, total_count} <- blocker_page(content["blockedBy"]),
         {:ok, remaining} <-
           fetch_blocker_pages(content["id"], page_info, total_count, settings, request_fun, []) do
      all_blockers = blockers ++ remaining

      if length(all_blockers) == total_count, do: {:ok, all_blockers}, else: incomplete_blockers()
    end
  end

  defp blocker_page(%{
         "nodes" => nodes,
         "pageInfo" => %{"hasNextPage" => has_next_page} = page_info,
         "totalCount" => total_count
       })
       when is_list(nodes) and is_boolean(has_next_page) and is_integer(total_count) and total_count >= 0 do
    with {:ok, blockers} <- normalize_blockers(nodes),
         :ok <- validate_blocker_page(blockers, page_info, total_count) do
      {:ok, blockers, page_info, total_count}
    end
  end

  defp blocker_page(_connection), do: incomplete_blockers()

  defp normalize_blockers(nodes) do
    blockers = Enum.map(nodes, &normalize_blocker/1)
    if Enum.any?(blockers, &is_nil/1), do: incomplete_blockers(), else: {:ok, blockers}
  end

  defp validate_blocker_page(blockers, page_info, total_count) do
    has_next_page = page_info["hasNextPage"]

    cond do
      total_count < length(blockers) -> incomplete_blockers()
      has_next_page and (blockers == [] or total_count == length(blockers)) -> incomplete_blockers()
      has_next_page and not (is_binary(page_info["endCursor"]) and page_info["endCursor"] != "") -> incomplete_blockers()
      true -> :ok
    end
  end

  defp normalize_blocker(%{
         "number" => number,
         "state" => state,
         "repository" => %{"nameWithOwner" => repository}
       })
       when is_integer(number) and number > 0 and is_binary(state) and
              is_binary(repository) and repository != "" do
    identity = "#{repository}##{number}"
    %{id: identity, identifier: identity, state: state}
  end

  defp normalize_blocker(_blocker), do: nil

  @spec fetch_blocker_pages(String.t() | nil, map(), non_neg_integer(), map(), function(), [String.t()]) ::
          {:ok, [map()]} | {:error, term()}
  defp fetch_blocker_pages(_issue_id, %{"hasNextPage" => false}, _total_count, _settings, _request_fun, _seen),
    do: {:ok, []}

  defp fetch_blocker_pages(
         issue_id,
         %{"hasNextPage" => true, "endCursor" => cursor},
         total_count,
         settings,
         request_fun,
         seen
       )
       when is_binary(issue_id) and is_binary(cursor) and cursor != "" do
    if cursor in seen do
      incomplete_blockers()
    else
      variables = %{"issueId" => issue_id, "after" => cursor}

      with {:ok, data} <- graphql(request_fun, @issue_blockers_query, variables, settings),
           {:ok, blockers, page_info, ^total_count} <- blocker_page(get_in(data, ["node", "blockedBy"])),
           {:ok, remaining} <-
             fetch_blocker_pages(issue_id, page_info, total_count, settings, request_fun, [cursor | seen]) do
        {:ok, blockers ++ remaining}
      else
        {:ok, _blockers, _page_info, _other_total_count} -> incomplete_blockers()
        other -> other
      end
    end
  end

  defp fetch_blocker_pages(_issue_id, _page_info, _total_count, _settings, _request_fun, _seen),
    do: incomplete_blockers()

  defp incomplete_blockers do
    {:error, {:github_projects_api_error, "GitHub returned incomplete issue dependency data."}}
  end

  defp maybe_block_unconfigured(item, status, settings, metadata, request_fun) do
    if normalize_state(status) == normalize_state(settings.statuses.blocked) do
      :ok
    else
      ref = item_ref(item, metadata, status)
      repository = get_in(item, ["content", "repository", "nameWithOwner"])
      reason = "No repository profile is configured for #{repository}. Add an exact owner/repository profile to tracker.provider.repositories."

      with :ok <- set_item_status(ref, settings.statuses.blocked, settings, request_fun) do
        add_issue_comment(ref, reason, settings, request_fun)
      end
    end
  end

  defp item_ref(item, metadata, status) do
    %{
      project_item_id: item["id"],
      project_id: metadata.project_id,
      status_field_id: metadata.status_field_id,
      status_option_ids: metadata.status_option_ids,
      project_status: status,
      issue_node_id: get_in(item, ["content", "id"])
    }
  end

  defp item_status(item, status_field) do
    item
    |> get_in(["fieldValues", "nodes"])
    |> case do
      values when is_list(values) ->
        Enum.find_value(values, &status_value(&1, status_field))

      _ ->
        nil
    end
  end

  defp status_value(value, status_field) do
    case get_in(value, ["field", "name"]) do
      ^status_field -> value["name"]
      _ -> nil
    end
  end

  defp update_issue_status(issue, status_key, reason, tracker_settings, request_fun) do
    with {:ok, settings} <- settings(tracker_settings),
         ref when is_map(ref) <- issue.native_ref,
         :ok <- ensure_claimable(issue, status_key, settings),
         :ok <- set_item_status(ref, Map.fetch!(settings.statuses, status_key), settings, request_fun),
         :ok <- maybe_add_block_reason(ref, status_key, reason, settings, request_fun) do
      :ok
    else
      nil -> {:error, {:github_projects_api_error, "Project item reference is missing."}}
      {:error, _reason} = error -> error
      _other -> {:error, {:github_projects_api_error, "Unable to update the Project item status."}}
    end
  end

  defp complete_issue(issue, tracker_settings, request_fun) do
    with {:ok, settings} <- settings(tracker_settings),
         {:ok, issues} <- fetch_issues_by_ids([issue.id], tracker_settings, request_fun) do
      issues
      |> Enum.find(&(&1.id == issue.id))
      |> complete_current_issue(settings, tracker_settings, request_fun)
    end
  end

  defp complete_current_issue(%Issue{state: "closed"}, _settings, _tracker_settings, _request_fun),
    do: :ok

  defp complete_current_issue(%Issue{native_ref: ref} = issue, settings, tracker_settings, request_fun)
       when is_map(ref) do
    if status_in?(ref_value(ref, :project_status), [settings.statuses.building]) do
      update_issue_status(issue, :done, nil, tracker_settings, request_fun)
    else
      :ok
    end
  end

  defp complete_current_issue(_issue, _settings, _tracker_settings, _request_fun), do: :ok

  defp ensure_claimable(issue, :building, settings) do
    issue_state = normalize_state(issue.state)
    project_status = normalize_state(ref_value(issue.native_ref, :project_status))

    cond do
      issue_state == normalize_state(settings.statuses.ready) and
          project_status == normalize_state(settings.statuses.ready) ->
        :ok

      issue_state == normalize_state(settings.statuses.building) and
          project_status == normalize_state(settings.statuses.building) ->
        :ok

      true ->
        {:error, {:github_projects_item_not_ready, issue.id}}
    end
  end

  defp ensure_claimable(issue, :done, settings) do
    if status_in?(ref_value(issue.native_ref, :project_status), [settings.statuses.building]) do
      :ok
    else
      {:error, {:github_projects_item_not_building, issue.id}}
    end
  end

  defp ensure_claimable(_issue, _status_key, _settings), do: :ok

  defp maybe_add_block_reason(_ref, _status_key, nil, _settings, _request_fun), do: :ok

  defp maybe_add_block_reason(ref, :blocked, reason, settings, request_fun),
    do: add_issue_comment(ref, reason, settings, request_fun)

  defp maybe_add_block_reason(_ref, _status_key, _reason, _settings, _request_fun), do: :ok

  defp set_item_status(ref, status, settings, request_fun) do
    option_id = Map.get(ref, :status_option_ids, Map.get(ref, "status_option_ids", %{}))[status]

    with id when is_binary(id) <- option_id,
         project_id when is_binary(project_id) <- ref_value(ref, :project_id),
         item_id when is_binary(item_id) <- ref_value(ref, :project_item_id),
         field_id when is_binary(field_id) <- ref_value(ref, :status_field_id),
         {:ok, _data} <-
           graphql(
             request_fun,
             @status_mutation,
             %{
               "projectId" => project_id,
               "itemId" => item_id,
               "fieldId" => field_id,
               "optionId" => id
             },
             settings
           ) do
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, {:github_projects_configuration_error, "Unable to resolve the configured Project status option."}}
    end
  end

  defp delivery_variables(issue, branch) do
    {owner, name} = split_repository(ref_value(issue.native_ref, :repository))
    %{"owner" => owner, "name" => name, "branch" => "refs/heads/" <> branch}
  end

  defp repository_for_issue(issue) do
    case split_repository(ref_value(issue.native_ref, :repository)) do
      {owner, name} when is_binary(owner) and is_binary(name) -> {:ok, %{owner: owner, name: name}}
      _ -> {:error, {:github_projects_configuration_error, "Pipeline issue has no configured repository."}}
    end
  end

  defp issue_repository_and_number(issue) do
    case String.split(issue.id, "#", parts: 2) do
      [repository, number] ->
        case Integer.parse(number) do
          {number, ""} ->
            {owner, name} = split_repository(repository)
            {:ok, %{"owner" => owner, "name" => name, "number" => number}}

          _ ->
            {:error, {:github_projects_api_error, "Pipeline issue identifier is invalid."}}
        end

      _ ->
        {:error, {:github_projects_api_error, "Pipeline issue identifier is invalid."}}
    end
  end

  defp issue_comment_has_marker?(issue_ref, marker, settings, request_fun, cursor) do
    variables = Map.put(issue_ref, "after", cursor)

    with {:ok, data} <- graphql(request_fun, @comments_query, variables, settings) do
      comments = get_in(data, ["repository", "issue", "comments"]) || %{}
      nodes = comments["nodes"] || []
      page_info = comments["pageInfo"] || %{}
      found? = Enum.any?(nodes, &String.contains?(&1["body"] || "", marker))

      cond do
        found? -> {:ok, true}
        page_info["hasNextPage"] -> issue_comment_has_marker?(issue_ref, marker, settings, request_fun, page_info["endCursor"])
        true -> {:ok, false}
      end
    end
  end

  defp find_pull_request(issue, branch, base, settings, request_fun) do
    variables = repository_for_issue(issue)

    with {:ok, repository} <- variables,
         {:ok, data} <-
           graphql(request_fun, @pull_request_query, pull_request_variables(repository, branch, base), settings) do
      nodes = get_in(data, ["repository", "pullRequests", "nodes"]) || []

      {:ok,
       nodes
       |> Enum.map(&normalize_pull_request/1)
       |> Enum.find(&(&1.branch == branch and &1.base == base and &1.state == "OPEN" and not &1.merged))}
    end
  end

  defp pull_request(issue, settings, request_fun) do
    branch = issue.branch_name
    base = ref_value(issue.native_ref, :base_branch)

    with {:ok, repository} <- repository_for_issue(issue),
         {:ok, data} <-
           graphql(request_fun, @pull_request_query, pull_request_variables(repository, branch, base), settings) do
      nodes = get_in(data, ["repository", "pullRequests", "nodes"]) || []
      pr = nodes |> Enum.map(&normalize_pull_request/1) |> Enum.find(&(&1.branch == branch and &1.base == base))
      {:ok, pr}
    end
  end

  defp pull_request_variables(repository, branch, base) do
    %{"owner" => repository.owner, "name" => repository.name, "branch" => branch, "base" => base}
  end

  defp create_pull_request(issue, repository, attrs, settings, request_fun) do
    variables = %{"owner" => repository.owner, "name" => repository.name}

    with {:ok, data} <- graphql(request_fun, @repository_query, variables, settings),
         repository_id when is_binary(repository_id) <- get_in(data, ["repository", "id"]),
         {:ok, issue_ref} <- issue_repository_and_number(issue),
         input = %{
           "repositoryId" => repository_id,
           "baseRefName" => attrs.base,
           "headRefName" => attrs.branch,
           "title" => issue.title,
           "body" => attrs[:body] || "Fixes ##{issue_ref["number"]}\n\nCreated by Symphony after the Build phase.",
           "draft" => true
         },
         {:ok, created} <- graphql(request_fun, @create_pull_request_mutation, %{"input" => input}, settings),
         %{} = pr <- get_in(created, ["createPullRequest", "pullRequest"]) do
      {:ok, normalize_pull_request(pr)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:github_projects_api_error, "GitHub did not create the pipeline pull request."}}
    end
  end

  defp normalize_pull_request(pr) do
    %{
      id: pr["id"],
      number: pr["number"],
      url: pr["url"],
      state: pr["state"],
      draft: pr["isDraft"],
      merged: is_binary(pr["mergedAt"]),
      base: pr["baseRefName"],
      branch: pr["headRefName"],
      sha: pr["headRefOid"],
      body: pr["body"]
    }
  end

  defp update_pull_request_body(pr, body, _settings, _request_fun) when not is_binary(body), do: {:ok, pr}

  defp update_pull_request_body(%{body: current} = pr, body, settings, request_fun) do
    cond do
      current == body ->
        {:ok, pr}

      is_binary(current) and String.contains?(current, "<!-- symphony:delivery -->") ->
        with {:ok, data} <- graphql(request_fun, @update_pull_request_body_mutation, %{"pullRequestId" => pr.id, "body" => body}, settings),
             %{} = updated <- get_in(data, ["updatePullRequest", "pullRequest"]) do
          {:ok, normalize_pull_request(updated)}
        else
          {:error, _reason} = error -> error
          _ -> {:error, {:github_projects_api_error, "Unable to update the pipeline pull request body."}}
        end

      true ->
        {:ok, pr}
    end
  end

  defp split_repository(repository) when is_binary(repository) do
    case String.split(repository, "/", parts: 2) do
      [owner, name] -> {owner, name}
      _ -> {nil, nil}
    end
  end

  defp split_repository(_repository), do: {nil, nil}

  defp add_issue_comment(ref, reason, settings, request_fun) do
    subject_id = ref_value(ref, :issue_node_id)

    if is_binary(subject_id) do
      body = "Symphony moved this Project item to Blocked: " <> String.slice(reason, 0, 2_000)

      with {:ok, _data} <-
             graphql(
               request_fun,
               @comment_mutation,
               %{"subjectId" => subject_id, "body" => body},
               settings
             ) do
        :ok
      end
    else
      {:error, {:github_projects_api_error, "Linked GitHub Issue has no node ID for the Blocked reason comment."}}
    end
  end

  defp graphql(request_fun, query, variables, settings) do
    case request_fun.(query, variables, settings) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        graphql_body(body)

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, {:github_projects_permission_error, "GitHub denied Projects access (HTTP #{status}). Grant the token Project read/write access and issue read/write access."}}

      {:ok, %{status: status}} ->
        {:error, {:github_projects_api_error, "GitHub Projects GraphQL request failed (HTTP #{status})."}}

      {:error, _reason} ->
        {:error, {:github_projects_api_error, "GitHub Projects GraphQL request failed before receiving a response."}}

      _other ->
        {:error, {:github_projects_api_error, "GitHub Projects GraphQL returned an invalid response."}}
    end
  end

  defp graphql_body(%{"errors" => errors, "data" => data})
       when is_list(errors) and errors != [] and is_map(data) do
    case {project_from_data(data), errors} do
      {%{}, [%{"type" => "NOT_FOUND", "path" => [owner]}]}
      when owner in ["user", "organization"] ->
        {:ok, data}

      _other ->
        graphql_errors(errors)
    end
  end

  defp graphql_body(%{"errors" => errors}) when is_list(errors) and errors != [],
    do: graphql_errors(errors)

  defp graphql_body(%{"data" => data}) when is_map(data), do: {:ok, data}
  defp graphql_body(_body), do: {:error, {:github_projects_api_error, "GitHub Projects GraphQL returned no data."}}

  defp graphql_errors(errors) do
    message = Enum.map_join(errors, "; ", &Map.get(&1, "message", "unknown GraphQL error"))
    lower = String.downcase(message)

    if String.contains?(
         lower,
         ["permission", "not accessible", "resource not found", "must have access", "could not resolve"]
       ) do
      {:error, {:github_projects_permission_error, "GitHub denied Project or issue access. Confirm token Project read/write and linked issue read/write permissions."}}
    else
      {:error, {:github_projects_api_error, message}}
    end
  end

  defp perform_request(query, variables, settings) do
    request_opts = [
      method: :post,
      url: settings.graphql_url,
      headers: [
        {"authorization", "Bearer #{settings.token}"},
        {"accept", "application/vnd.github+json"},
        {"content-type", "application/json"},
        {"user-agent", "symphony"}
      ],
      json: %{"query" => query, "variables" => variables},
      connect_options: [timeout: 30_000]
    ]

    case Req.request(request_opts) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)

    with {:ok, project} <- project_settings(provider),
         {:ok, profiles} <- repository_settings(provider),
         {:ok, graphql_url} <- graphql_url_setting(provider),
         {:ok, token} <- token_setting(provider),
         :ok <- validate_pipeline_profiles(profiles),
         :ok <- validate_routing_settings(tracker_settings) do
      {:ok,
       Map.merge(project, %{
         statuses: @statuses,
         repositories: profiles,
         graphql_url: String.trim_trailing(graphql_url, "/"),
         token: token
       })}
    end
  end

  defp settings(_tracker_settings), do: invalid_settings(:invalid_tracker_settings)

  defp project_settings(provider) do
    owner = normalize_string(provider["owner"])
    project_number = provider["project_number"]

    cond do
      is_nil(owner) -> invalid_settings(:missing_owner)
      not is_integer(project_number) or project_number <= 0 -> invalid_settings(:invalid_project_number)
      true -> {:ok, %{owner: owner, project_number: project_number, status_field: @status_field}}
    end
  end

  defp repository_settings(provider) do
    case repository_profiles(provider["repositories"]) do
      nil -> invalid_settings(:invalid_repository_profiles)
      profiles -> {:ok, profiles}
    end
  end

  defp graphql_url_setting(provider) do
    graphql_url = provider["graphql_url"] || @default_graphql_url

    if valid_graphql_url?(graphql_url),
      do: {:ok, graphql_url},
      else: invalid_settings(:invalid_graphql_url)
  end

  defp token_setting(provider) do
    token = resolve_setting(provider["token"], System.get_env("GITHUB_TOKEN"))

    if present_string?(token),
      do: {:ok, token},
      else: invalid_settings(:missing_token)
  end

  defp validate_routing_settings(tracker_settings) do
    cond do
      Map.get(tracker_settings, :required_labels, []) not in [nil, []] ->
        invalid_settings(:required_labels_not_supported)

      not valid_active_states(Map.get(tracker_settings, :active_states)) ->
        invalid_settings(:active_states_must_include_canonical_active_states)

      not valid_terminal_states(Map.get(tracker_settings, :terminal_states)) ->
        invalid_settings(:terminal_states_must_include_closed_and_dropped)

      true ->
        :ok
    end
  end

  defp repository_profiles(profiles) when is_list(profiles) and profiles != [] do
    Enum.reduce_while(profiles, %{}, fn profile, acc ->
      repository = normalize_string(profile_value(profile, "repository"))
      base_branch = normalize_string(profile_value(profile, "base_branch"))
      prepare_command = normalize_string(profile_value(profile, "prepare_command"))
      required_checks = normalize_required_checks(profile_value(profile, "required_checks"))
      key = normalize_repository(repository)

      if valid_repository?(repository) and present_string?(base_branch) and
           present_string?(prepare_command) and not is_nil(required_checks) and not Map.has_key?(acc, key) do
        normalized = %{
          repository: repository,
          base_branch: base_branch,
          prepare_command: prepare_command,
          required_checks: required_checks
        }

        {:cont, Map.put(acc, key, normalized)}
      else
        {:halt, nil}
      end
    end)
  end

  defp repository_profiles(_profiles), do: nil

  defp normalize_required_checks(nil), do: []

  defp normalize_required_checks(checks) when is_list(checks) do
    normalized = Enum.map(checks, &normalize_string/1)
    if Enum.all?(normalized, &present_string?/1), do: Enum.uniq(normalized), else: nil
  end

  defp normalize_required_checks(_checks), do: nil

  defp validate_pipeline_profiles(profiles) do
    if Enum.any?(profiles, fn {_repo, profile} -> profile.required_checks == [] end) do
      invalid_settings(:pipeline_requires_repository_required_checks)
    else
      :ok
    end
  end

  defp valid_active_states(states) when is_list(states) do
    normalized = MapSet.new(states, &normalize_state/1)

    Enum.all?(
      [@statuses.ready, @statuses.building, @statuses.qa, @statuses.review, @statuses.human_review],
      &MapSet.member?(normalized, normalize_state(&1))
    ) and
      Enum.all?(
        [@statuses.backlog, @statuses.blocked, @statuses.done, @statuses.dropped],
        &(not MapSet.member?(normalized, normalize_state(&1)))
      )
  end

  defp valid_active_states(_states), do: false

  defp valid_terminal_states(states) when is_list(states) do
    normalized = MapSet.new(states, &normalize_state/1)

    MapSet.member?(normalized, "closed") and
      Enum.all?([@statuses.done, @statuses.blocked], &(not MapSet.member?(normalized, normalize_state(&1)))) and
      MapSet.member?(normalized, normalize_state(@statuses.dropped))
  end

  defp valid_terminal_states(_states), do: false

  defp invalid_settings(reason),
    do: {:error, {:invalid_github_projects_settings, reason}}

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(%{"provider" => provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp profile_value(profile, key) when is_map(profile), do: Map.get(profile, key) || Map.get(profile, String.to_atom(key))
  defp profile_value(_profile, _key), do: nil

  defp ref_value(ref, key), do: Map.get(ref, key) || Map.get(ref, Atom.to_string(key))

  defp extract_labels(content) do
    get_in(content, ["labels", "nodes"])
    |> case do
      labels when is_list(labels) ->
        labels
        |> Enum.map(&label_name/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp label_name(%{"name" => name}) when is_binary(name), do: String.downcase(name)
  defp label_name(_label), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp work_branch(repository, number) do
    slug = String.replace(String.downcase(repository), ~r/[^a-z0-9-]/, "-")
    "symphony/#{slug}-#{number}"
  end

  defp status_in?(status, values) do
    normalized = normalize_state(status)
    Enum.any?(values, &(normalize_state(&1) == normalized))
  end

  defp normalize_repository(repository) when is_binary(repository), do: String.downcase(String.trim(repository))
  defp normalize_repository(_repository), do: ""

  defp valid_repository?(repository) when is_binary(repository),
    do: String.match?(repository, ~r/^[^\/\s]+\/[^\/\s]+$/)

  defp valid_repository?(_repository), do: false

  defp valid_graphql_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_graphql_url?(_url), do: false

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name), do: normalize_string(System.get_env(env_name) || fallback), else: nil
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  @spec valid_env_name?(String.t()) :: boolean()
  defp valid_env_name?(value), do: String.match?(value, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp env_reference_names("$" <> env_name) do
    if valid_env_name?(env_name), do: [env_name], else: []
  end

  defp env_reference_names(_value), do: []
end
