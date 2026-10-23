defmodule SymphonyElixir.GitHub.Projects.Client do
  @moduledoc """
  GitHub Projects v2 GraphQL client for issue-backed work items.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.AgentReport
  alias SymphonyElixir.Pipeline.Findings
  alias SymphonyElixir.Pipeline.Store
  alias SymphonyElixir.PRBody
  alias SymphonyElixir.Tracker.Issue

  @default_graphql_url "https://api.github.com/graphql"
  @page_size 100
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
      commentEdge { node { id url } }
    }
  }
  """

  @merge_query """
  query SymphonyPipelineMergeGate($owner: String!, $name: String!, $branch: String!, $base: String!, $baseRef: String!) {
    repository(owner: $owner, name: $name) {
      ref(qualifiedName: $baseRef) { target { ... on Commit { oid } } }
      pullRequests(first: 100, states: [OPEN, CLOSED, MERGED], headRefName: $branch, baseRefName: $base) {
        nodes { id number url state isDraft mergedAt baseRefName baseRefOid headRefName headRefOid statusCheckRollup { state } }
      }
    }
  }
  """

  @close_issue_mutation """
  mutation SymphonyPipelineCloseIssue($issueId: ID!) {
    closeIssue(input: { issueId: $issueId }) { issue { id state stateReason url } }
  }
  """

  @add_project_item_mutation """
  mutation SymphonyAddFollowUpToProject($projectId: ID!, $contentId: ID!) {
    addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) { item { id } }
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
        nodes { id number url state isDraft mergedAt baseRefName baseRefOid headRefName headRefOid reviewDecision body }
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
      issue(number: $number) { comments(first: 100, after: $after) { nodes { id url body author { login } } pageInfo { hasNextPage endCursor } } }
    }
  }
  """

  @viewer_query "query SymphonyPipelineViewer { viewer { login } }"

  @update_comment_mutation """
  mutation SymphonyUpdateAgentReport($id: ID!, $body: String!) {
    updateIssueComment(input: { id: $id, body: $body }) { issueComment { id url body } }
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
         :ok <- validate_pipeline_delivery(issue, branch, sha, settings, &perform_request/3) do
      :ok
    else
      {:error, _reason} = error -> error
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

  defp update_pull_request_stage(pr, stage, settings, request_fun \\ &perform_request/3)

  defp update_pull_request_stage(%{draft: draft} = pr, stage, _settings, _request_fun) when draft == (stage == :draft),
    do: {:ok, pr}

  defp update_pull_request_stage(pr, stage, settings, request_fun) do
    {mutation, result_key} = pull_request_stage_mutation(stage)

    case graphql(request_fun, mutation, %{"pullRequestId" => pr.id}, settings) do
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

  @spec agent_operation(Issue.t(), map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def agent_operation(%Issue{} = issue, context, operation, arguments, opts)
      when is_map(context) and is_binary(operation) and is_map(arguments) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    base_request = Keyword.get(opts, :projects_request, &perform_request/3)
    base_rest = Keyword.get(opts, :github_rest, &perform_rest_request/5)

    with :ok <- validate_agent_lease(context),
         {:ok, settings} <- settings(tracker_settings),
         :ok <- ensure_agent_repository(issue, settings) do
      request_fun = agent_graphql_request(context, base_request)
      rest_fun = agent_rest_request(context, base_rest)
      opts = opts |> Keyword.put(:projects_request, request_fun) |> Keyword.put(:github_rest, rest_fun)
      dispatch_agent_operation(issue, context, operation, arguments, tracker_settings, settings, request_fun, opts)
    end
  end

  defp dispatch_agent_operation(issue, context, operation, arguments, tracker_settings, settings, request_fun, opts) do
    case operation do
      "claim" -> agent_claim(issue, tracker_settings, settings, request_fun)
      "read_workpad" -> agent_read_workpad(issue, context, settings, request_fun)
      "workpad" -> agent_workpad(issue, arguments, settings, request_fun)
      "handoff" -> agent_handoff(issue, context, arguments, tracker_settings, settings, request_fun)
      "create_follow_up_issue" -> create_follow_up_issue(issue, context, arguments, tracker_settings, settings, opts)
      "request_merge" -> request_merge(issue, context, tracker_settings, settings, request_fun, opts)
      "release_claim" -> {:error, :project_claim_released_by_handoff}
      _ -> {:error, :unsupported_github_workflow_operation}
    end
  end

  defp agent_graphql_request(context, request_fun) do
    fn query, variables, request_settings ->
      with_valid_agent_lease(context, fn -> request_fun.(query, variables, request_settings) end)
    end
  end

  defp agent_rest_request(context, request_fun) do
    fn method, path, params, body, request_settings ->
      with_valid_agent_lease(context, fn -> request_fun.(method, path, params, body, request_settings) end)
    end
  end

  defp with_valid_agent_lease(context, request_fun) do
    with :ok <- validate_agent_lease(context), do: request_fun.()
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

  defp normalize_linked_issue(item, metadata, settings, _request_fun, blockers) do
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
        {:ok, nil}

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

  defp validate_pipeline_delivery(issue, branch, sha, settings, request_fun) do
    with {:ok, data} <- graphql(request_fun, @delivery_query, delivery_variables(issue, branch), settings),
         %{"target" => %{"oid" => ^sha}} <- get_in(data, ["repository", "ref"]) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:github_projects_api_error, "The pushed branch does not contain the reported SHA in the configured repository."}}
    end
  end

  defp validate_agent_lease(%{lane: lane, generation: generation, attempt: attempt, issue: %Issue{id: issue_id}} = context)
       when lane not in [:individual, "individual"] and is_integer(generation) and is_integer(attempt) do
    lease_phase = Map.get(context, :lease_phase) || lane

    if Store.agent_lease_active?(issue_id, generation, to_string(lease_phase), attempt),
      do: :ok,
      else: {:error, :stale_agent_lease}
  end

  defp validate_agent_lease(%{lane: lane, issue: %Issue{id: issue_id}, lease_token: token})
       when lane in [:individual, "individual"] and is_binary(token) do
    if Store.agent_lease_active?(issue_id, token),
      do: :ok,
      else: {:error, :stale_agent_lease}
  end

  defp validate_agent_lease(_context), do: {:error, :missing_agent_lease}

  defp ensure_agent_repository(issue, settings) do
    with {:ok, repository} <- repository_for_issue(issue),
         true <- Map.has_key?(settings.repositories, normalize_repository("#{repository.owner}/#{repository.name}")) do
      :ok
    else
      false -> {:error, :github_repository_not_configured}
      {:error, _reason} = error -> error
    end
  end

  defp agent_claim(issue, tracker_settings, settings, request_fun) do
    with {:ok, current} <- current_project_issue(issue, tracker_settings, request_fun),
         :ok <- claimable_project_status(issue, current, settings),
         :ok <- maybe_set_project_status(current, settings.statuses.building, settings, request_fun),
         {:ok, claimed} <- current_project_issue(issue, tracker_settings, request_fun),
         true <- project_status(claimed) == settings.statuses.building do
      {:ok, project_evidence(issue, claimed, settings.statuses.building)}
    else
      false -> {:error, :github_project_claim_not_verified}
      {:error, _reason} = error -> error
    end
  end

  defp agent_handoff(issue, context, arguments, tracker_settings, settings, request_fun) do
    lane = to_string(context.lane)
    report = normalize_report(Map.get(arguments, "report"))
    outcome = Map.get(arguments, "outcome") || report["outcome"]
    report = report |> Map.put("outcome", outcome) |> normalize_agent_report(lane, context)
    body = Map.get(arguments, "body")

    with :ok <- validate_agent_pr_body(lane, report, issue),
         :ok <- AgentReport.validate_body(body, report),
         {:ok, status} <- handoff_status(lane, report, settings),
         {:ok, current} <- current_project_issue(issue, tracker_settings, request_fun),
         :ok <- handoff_source_status(lane, current, status, settings),
         {:ok, pr} <- handoff_pull_request(issue, context, report, tracker_settings, settings, request_fun),
         {:ok, pr} <- maybe_set_review_stage(issue, lane, report, pr, status, settings, tracker_settings, request_fun),
         {:ok, closed_issue} <-
           maybe_finalize_merged_issue(issue, context, report, pr, tracker_settings, settings, request_fun),
         {:ok, comment} <-
           publish_agent_report(issue, context, body, status, settings, tracker_settings, request_fun),
         {:ok, status_evidence} <-
           apply_project_status(issue, current, status, lane, settings, tracker_settings, request_fun) do
      {:ok,
       %{
         "outcome" => report["outcome"],
         "issue" => %{"id" => issue.id, "url" => issue.url},
         "closed_issue" => closed_issue,
         "project_item" => status_evidence,
         "comment" => comment,
         "pull_request" => pr,
         "sha" => report["sha"]
       }}
    end
  end

  defp validate_agent_pr_body(lane, %{"outcome" => "ready"} = report, issue) when lane in ["build", "individual"],
    do: PRBody.validate_agent_body(report["pull_request_body"], issue.id)

  defp validate_agent_pr_body(_lane, _report, _issue), do: :ok

  defp handoff_status("build", %{"outcome" => "ready"}, settings), do: {:ok, settings.statuses.qa}
  defp handoff_status("build", %{"outcome" => outcome}, settings) when outcome in ["blocked", "no_changes"], do: {:ok, settings.statuses.blocked}
  defp handoff_status("qa", %{"outcome" => "passed"}, settings), do: {:ok, settings.statuses.review}
  defp handoff_status("qa", %{"outcome" => outcome}, settings) when outcome in ["changes_requested", "failed", "defects_found"], do: {:ok, settings.statuses.building}
  defp handoff_status("qa", %{"outcome" => "blocked"}, settings), do: {:ok, settings.statuses.blocked}
  defp handoff_status("review", %{"outcome" => "passed", "findings" => []}, settings), do: {:ok, settings.statuses.human_review}
  defp handoff_status("review", %{"outcome" => "merged"}, settings), do: {:ok, settings.statuses.done}
  defp handoff_status("review", %{"outcome" => outcome}, settings) when outcome in ["changes_requested", "failed", "defects_found"], do: {:ok, settings.statuses.building}
  defp handoff_status("review", %{"outcome" => "blocked"}, settings), do: {:ok, settings.statuses.blocked}
  defp handoff_status("diagnostic", %{"outcome" => "blocked"}, settings), do: {:ok, settings.statuses.blocked}
  defp handoff_status("finalize", %{"outcome" => "merged"}, settings), do: {:ok, settings.statuses.done}
  defp handoff_status("individual", %{"outcome" => outcome}, _settings) when outcome in ["ready", "blocked", "no_changes"], do: {:ok, nil}
  defp handoff_status(_lane, _report, _settings), do: {:error, :invalid_github_handoff}

  defp normalize_agent_report(report, "build", context) do
    task = context[:task] || %{}
    Map.merge(report, Map.take(task, ["branch", "base_branch", "required_checks"]))
  end

  defp normalize_agent_report(report, "qa", context) do
    checks = normalize_report_list(context[:host_checks])
    required = get_in(context, [:task, "required_checks"]) || []
    report = Map.put(report, "checks", checks)

    cond do
      not required_checks_passed?(required, checks) and Enum.any?(checks, &(&1["status"] == "unavailable")) ->
        report
        |> Map.put("outcome", "blocked")
        |> Map.put("reason", qa_text(context, :checks_unavailable))

      not required_checks_passed?(required, checks) ->
        report
        |> Map.put("outcome", "changes_requested")
        |> Map.put("summary", qa_text(context, :checks_failed))

      report["outcome"] == "passed" and report["findings"] not in [nil, []] ->
        Map.merge(report, %{
          "outcome" => "changes_requested",
          "summary" => qa_text(context, :findings),
          "next_step" => qa_text(context, :next_step)
        })

      true ->
        report
    end
  end

  defp normalize_agent_report(report, "review", context) do
    resolutions = report["resolutions"] || []
    task = context[:task] || %{}
    prior_findings = task["prior_findings"] || []
    pending_findings = Enum.reject(prior_findings, &Findings.resolved?(&1["id"], resolutions))
    findings = Enum.uniq_by((report["findings"] || []) ++ pending_findings, & &1["id"])

    metadata =
      task
      |> Map.take(["branch", "base_branch", "pr_number"])
      |> Map.merge(if(is_binary(task["current_sha"]), do: %{"sha" => task["current_sha"]}, else: %{}))

    report = report |> Map.put("findings", findings) |> Map.merge(metadata)

    if report["outcome"] == "passed" and findings != [],
      do: Map.put(report, "outcome", "changes_requested"),
      else: report
  end

  defp normalize_agent_report(report, _lane, _context), do: report

  defp qa_text(%{report_locale: :es}, :checks_unavailable), do: "Symphony no pudo ejecutar todas las comprobaciones requeridas."
  defp qa_text(%{report_locale: :es}, :checks_failed), do: "Falló alguna comprobación requerida o falta evidencia para confirmarla."
  defp qa_text(%{report_locale: :es}, :findings), do: "QA encontró hallazgos que requieren corrección."
  defp qa_text(%{report_locale: :es}, :next_step), do: "Corrige los hallazgos y vuelve a entregar el trabajo en Build."
  defp qa_text(_context, :checks_unavailable), do: "Symphony could not execute every configured required check."
  defp qa_text(_context, :checks_failed), do: "One or more required host checks failed or were missing."
  defp qa_text(_context, :findings), do: "QA reported findings that need correction."
  defp qa_text(_context, :next_step), do: "Fix the findings and submit a new Build delivery."

  @doc false
  @spec normalize_agent_report_for_test(map(), String.t(), map()) :: map()
  def normalize_agent_report_for_test(report, lane, context),
    do: normalize_agent_report(report, lane, context)

  defp handoff_source_status(lane, current, target, settings) do
    sources =
      case lane do
        "build" -> [settings.statuses.building]
        "qa" -> [settings.statuses.qa]
        "review" -> if(target == settings.statuses.done, do: [settings.statuses.review, settings.statuses.human_review], else: [settings.statuses.review])
        "diagnostic" -> Enum.map([:building, :qa, :review], &Map.fetch!(settings.statuses, &1))
        "finalize" -> [settings.statuses.human_review]
        "individual" -> [project_status(current)]
        _ -> []
      end

    expected_project_status(current, [target | sources])
  end

  defp handoff_pull_request(issue, context, _report, _tracker_settings, settings, request_fun)
       when context.lane in [:qa, :review, :finalize, "qa", "review", "finalize"] do
    return_existing_pull_request(issue, context, settings, request_fun)
  end

  defp handoff_pull_request(issue, context, %{"outcome" => "ready", "sha" => sha} = report, tracker_settings, settings, request_fun)
       when is_binary(sha) do
    lane = to_string(context.lane)

    task = Map.get(context, :task) || %{}
    profile = profile_for_issue(issue, settings)
    branch = task["branch"] || issue.branch_name
    base = task["base_branch"] || profile.base_branch
    body = delivery_body(report)

    with :ok <- validate_handoff_source_for_lane(lane, issue, tracker_settings, settings, request_fun),
         :ok <- validate_pipeline_delivery(issue, branch, sha, settings, request_fun),
         {:ok, pr} <-
           upsert_pull_request(
             issue,
             %{branch: branch, base: base, sha: sha, body: body},
             tracker_settings,
             request_fun
           ),
         {:ok, pr} <- update_pull_request_stage(pr, :draft, settings, request_fun),
         :ok <- ensure_pull_request_sha(pr, sha),
         true <- pr.draft do
      {:ok, pr_evidence(pr)}
    else
      false -> {:error, :pipeline_pull_request_not_draft}
      {:error, _reason} = error -> error
      _ -> {:error, :pipeline_pull_request_upsert_failed}
    end
  end

  defp handoff_pull_request(_issue, _context, _report, _tracker_settings, _settings, _request_fun), do: {:ok, nil}

  defp validate_handoff_source_for_lane("build", issue, tracker_settings, settings, request_fun),
    do: validate_build_handoff_source(issue, tracker_settings, settings, request_fun)

  defp validate_handoff_source_for_lane(_lane, _issue, _tracker_settings, _settings, _request_fun), do: :ok

  defp validate_build_handoff_source(issue, tracker_settings, settings, request_fun) do
    with {:ok, current} <- current_project_issue(issue, tracker_settings, request_fun) do
      handoff_source_status("build", current, settings.statuses.qa, settings)
    end
  end

  defp return_existing_pull_request(issue, context, settings, request_fun) do
    case pull_request(issue, settings, request_fun) do
      {:ok, nil} ->
        {:error, :pull_request_not_found}

      {:ok, pr} ->
        expected_sha = get_in(context, [:task, "current_sha"])
        if is_binary(expected_sha) and pr.sha != expected_sha, do: {:error, :pull_request_head_sha_mismatch}, else: {:ok, pr_evidence(pr)}

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_set_review_stage(issue, "review", %{"outcome" => outcome}, _pr, target, settings, tracker_settings, request_fun)
       when outcome in ["passed", "changes_requested", "failed", "defects_found"] do
    stage = if outcome == "passed", do: :ready, else: :draft

    with {:ok, current} <- current_project_issue(issue, tracker_settings, request_fun),
         :ok <- handoff_source_status("review", current, target, settings),
         {:ok, %{} = pr} <- pull_request(issue, settings, request_fun),
         {:ok, updated} <- update_pull_request_stage(pr, stage, settings, request_fun) do
      {:ok, pr_evidence(updated)}
    end
  end

  defp maybe_set_review_stage(_issue, _lane, _report, pr, _target, _settings, _tracker_settings, _request_fun), do: {:ok, pr}

  defp maybe_finalize_merged_issue(_issue, _context, %{"outcome" => outcome}, _pr, _tracker_settings, _settings, _request_fun)
       when outcome != "merged",
       do: {:ok, nil}

  defp maybe_finalize_merged_issue(issue, context, %{"outcome" => "merged", "sha" => sha}, pr, tracker_settings, settings, request_fun) do
    expected_base = get_in(context, [:task, "base_branch"]) || ref_value(issue.native_ref, :base_branch)

    with true <- to_string(context.lane) in ["review", "finalize"],
         true <- pr["merged"] == true and pr["base"] == expected_base and pr["head_sha"] == sha,
         {:ok, current} <- current_project_issue(issue, tracker_settings, request_fun),
         {:ok, current_pr} <- pull_request(current, settings, request_fun),
         true <- current_pr && current_pr.merged && current_pr.base == expected_base && current_pr.sha == sha,
         {:ok, closed} <- close_merged_issue(current, settings, request_fun) do
      {:ok, closed}
    else
      false -> {:error, :merge_not_verified_for_finalization}
      {:error, _reason} = error -> error
      _ -> {:error, :merge_not_verified_for_finalization}
    end
  end

  defp maybe_finalize_merged_issue(_issue, _context, _report, _pr, _tracker_settings, _settings, _request_fun),
    do: {:error, :invalid_merged_handoff}

  defp publish_agent_report(issue, context, body, target, settings, tracker_settings, request_fun) do
    phase = to_string(context.lane)
    marker = agent_report_marker(issue, context, phase)

    with {:ok, current} <- current_project_issue(issue, tracker_settings, request_fun),
         :ok <- handoff_source_status(phase, current, target, settings),
         {:ok, issue_ref} <- issue_repository_and_number(issue),
         {:ok, existing} <- find_issue_comment(marker, issue_ref, settings, request_fun, nil) do
      case existing do
        %{} = comment -> update_owned_agent_report(comment, marker, body, settings, request_fun)
        nil -> create_agent_report(issue, marker, body, settings, request_fun)
      end
    end
  end

  defp find_issue_comment(marker, issue_ref, settings, request_fun, cursor) do
    with {:ok, data} <- graphql(request_fun, @comments_query, Map.put(issue_ref, "after", cursor), settings) do
      comments = get_in(data, ["repository", "issue", "comments"]) || %{}
      nodes = comments["nodes"] || []
      page_info = comments["pageInfo"] || %{}
      found = Enum.find(nodes, &String.contains?(&1["body"] || "", marker))

      cond do
        found -> {:ok, found}
        page_info["hasNextPage"] -> find_issue_comment(marker, issue_ref, settings, request_fun, page_info["endCursor"])
        true -> {:ok, nil}
      end
    end
  end

  defp agent_read_workpad(issue, context, settings, request_fun) do
    with {:ok, issue_ref} <- issue_repository_and_number(issue),
         {:ok, comments} <- list_issue_comments(issue_ref, settings, request_fun, nil, []),
         {:ok, viewer_data} <- graphql(request_fun, @viewer_query, %{}, settings),
         viewer when is_binary(viewer) <- get_in(viewer_data, ["viewer", "login"]),
         comments = Enum.filter(comments, &(get_in(&1, ["author", "login"]) == viewer)),
         phase_reports = current_generation_phase_reports(issue, context[:generation] || 0, comments),
         :ok <- validate_review_qa_report(context, phase_reports) do
      workpad = Enum.find(comments, &String.contains?(&1["body"] || "", "<!-- symphony:workpad:start -->"))

      {:ok,
       %{
         "issue" => %{"id" => issue.id, "url" => issue.url},
         "workpad" => if(workpad, do: task_comment(workpad)),
         "phase_reports" => phase_reports,
         "report_context" => agent_report_context(context)
       }}
    else
      nil -> {:error, :github_agent_identity_missing}
      {:error, _reason} = error -> error
      _ -> {:error, :github_agent_identity_missing}
    end
  end

  defp current_generation_phase_reports(issue, generation, comments) do
    Enum.reduce(~w(build qa review finalize), %{}, fn phase, reports ->
      marker = phase_report_marker(issue, generation, phase)

      phase_reports =
        comments
        |> Enum.filter(&phase_report_comment?(&1["body"] || "", marker))
        |> Enum.map(&Map.put(task_comment(&1), "attempt", phase_report_attempt(&1["body"] || "", marker)))
        |> Enum.sort_by(& &1["attempt"])

      if phase_reports == [], do: reports, else: Map.put(reports, phase, phase_reports)
    end)
  end

  defp validate_review_qa_report(%{lane: lane, task: task}, phase_reports)
       when lane in [:review, "review"] and is_map(task) do
    with %{"body" => body} <- latest_phase_report(phase_reports, "qa"),
         {:ok, report} <- decode_phase_report_comment(body),
         true <- report["outcome"] == "passed",
         true <- report["sha"] == task["current_sha"],
         true <- required_checks_passed?(task["required_checks"] || [], report["checks"] || []) do
      :ok
    else
      _ -> {:error, :qa_evidence_unavailable}
    end
  end

  defp validate_review_qa_report(%{lane: lane}, _phase_reports) when lane in [:review, "review"],
    do: {:error, :qa_evidence_unavailable}

  defp validate_review_qa_report(_context, _phase_reports), do: :ok

  defp latest_phase_report(phase_reports, phase), do: phase_reports |> Map.get(phase, []) |> List.last()

  defp phase_report_marker(issue, generation, phase),
    do: "<!-- symphony:report:start:#{issue.id}:#{generation}:#{phase}"

  defp phase_report_comment?(body, marker),
    do: String.contains?(body, marker <> " -->") or String.contains?(body, marker <> ":")

  defp phase_report_attempt(body, marker) do
    case Regex.run(~r/#{Regex.escape(marker)}:(\d+) -->/, body) do
      [_, attempt] -> String.to_integer(attempt)
      _ -> 0
    end
  end

  defp decode_phase_report_comment(body) do
    AgentReport.decode_comment(body)
  end

  defp agent_report_context(context) do
    lane = to_string(context.lane)
    task = context[:task]
    task = if is_map(task), do: task, else: %{}

    fields =
      case lane do
        "build" -> ["branch", "base_branch", "required_checks"]
        "qa" -> ["current_sha", "required_checks"]
        "review" -> ["branch", "base_branch", "pr_number", "current_sha", "prior_findings"]
        "finalize" -> ["branch", "base_branch", "pr_number", "current_sha"]
        _ -> []
      end

    report_context = %{"lane" => lane, "task" => Map.take(task, fields)}

    if lane == "qa" do
      locale = context[:report_locale] || :en

      Map.merge(report_context, %{
        "host_checks" => normalize_report_list(context[:host_checks]),
        "report_locale" => to_string(locale),
        "qa_text" => %{
          "checks_unavailable" => qa_text(%{report_locale: locale}, :checks_unavailable),
          "checks_failed" => qa_text(%{report_locale: locale}, :checks_failed),
          "findings" => qa_text(%{report_locale: locale}, :findings),
          "next_step" => qa_text(%{report_locale: locale}, :next_step)
        }
      })
    else
      report_context
    end
  end

  defp list_issue_comments(issue_ref, settings, request_fun, cursor, comments) do
    with {:ok, data} <- graphql(request_fun, @comments_query, Map.put(issue_ref, "after", cursor), settings) do
      connection = get_in(data, ["repository", "issue", "comments"]) || %{}
      nodes = connection["nodes"] || []
      page_info = connection["pageInfo"] || %{}
      comments = comments ++ nodes

      if page_info["hasNextPage"],
        do: list_issue_comments(issue_ref, settings, request_fun, page_info["endCursor"], comments),
        else: {:ok, comments}
    end
  end

  defp task_comment(comment), do: %{"id" => comment["id"], "url" => comment["url"], "body" => comment["body"]}

  defp agent_workpad(issue, arguments, settings, request_fun) do
    body = Map.get(arguments, "body")
    marker = "<!-- symphony:workpad:start -->"
    end_marker = "<!-- symphony:workpad:end -->"

    with body when is_binary(body) and byte_size(body) in 1..60_000 <- body,
         false <- String.contains?(body, [marker, end_marker]),
         {:ok, issue_ref} <- issue_repository_and_number(issue),
         {:ok, existing} <- find_issue_comment(marker, issue_ref, settings, request_fun, nil),
         content = workpad_body(body, marker, end_marker),
         {:ok, evidence} <- upsert_agent_workpad(issue, existing, marker, end_marker, content, settings, request_fun) do
      {:ok, %{"issue" => %{"id" => issue.id, "url" => issue.url}, "comment" => evidence}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_github_workpad}
    end
  end

  defp upsert_agent_workpad(issue, nil, marker, _end_marker, body, settings, request_fun) do
    with subject_id when is_binary(subject_id) <- ref_value(issue.native_ref, :issue_node_id),
         {:ok, data} <- graphql(request_fun, @comment_mutation, %{"subjectId" => subject_id, "body" => body}, settings),
         %{} = comment <- get_in(data, ["addComment", "commentEdge", "node"]) do
      {:ok, comment_evidence(comment, marker)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_workpad_create_failed}
    end
  end

  defp upsert_agent_workpad(_issue, comment, marker, end_marker, replacement, settings, request_fun) do
    with {:ok, viewer_data} <- graphql(request_fun, @viewer_query, %{}, settings),
         viewer when is_binary(viewer) <- get_in(viewer_data, ["viewer", "login"]),
         true <- get_in(comment, ["author", "login"]) == viewer,
         {:ok, body} <- replace_owned_comment_block(comment["body"] || "", marker, end_marker, replacement) do
      if body == comment["body"],
        do: {:ok, comment_evidence(comment, marker)},
        else: update_agent_workpad(comment, marker, body, settings, request_fun)
    else
      false -> {:error, :github_agent_workpad_not_owned}
      nil -> {:error, :github_agent_identity_missing}
      {:error, _reason} = error -> error
      _ -> {:error, :github_workpad_update_failed}
    end
  end

  defp update_agent_workpad(comment, marker, body, settings, request_fun) do
    with {:ok, data} <- graphql(request_fun, @update_comment_mutation, %{"id" => comment["id"], "body" => body}, settings),
         %{} = updated <- get_in(data, ["updateIssueComment", "issueComment"]) do
      {:ok, comment_evidence(updated, marker)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_workpad_update_failed}
    end
  end

  defp workpad_body(body, marker, end_marker) do
    content = String.trim(body)
    content = if String.starts_with?(content, "## Codex Workpad"), do: content, else: "## Codex Workpad\n\n" <> content
    marker <> "\n" <> content <> "\n" <> end_marker
  end

  defp create_agent_report(issue, marker, agent_body, settings, request_fun) do
    body = AgentReport.comment_body(marker, agent_body)
    subject_id = ref_value(issue.native_ref, :issue_node_id)

    with subject_id when is_binary(subject_id) <- subject_id,
         {:ok, data} <- graphql(request_fun, @comment_mutation, %{"subjectId" => subject_id, "body" => body}, settings),
         %{} = comment <- get_in(data, ["addComment", "commentEdge", "node"]) do
      {:ok, comment_evidence(comment, marker)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:github_projects_api_error, "Unable to verify the phase report comment."}}
    end
  end

  defp update_owned_agent_report(comment, marker, agent_body, settings, request_fun) do
    with {:ok, viewer_data} <- graphql(request_fun, @viewer_query, %{}, settings),
         viewer when is_binary(viewer) <- get_in(viewer_data, ["viewer", "login"]),
         true <- get_in(comment, ["author", "login"]) == viewer,
         {:ok, body} <-
           replace_owned_comment_block(
             comment["body"] || "",
             marker,
             "<!-- symphony:report:end -->",
             AgentReport.comment_body(marker, agent_body)
           ),
         {:ok, data} <- graphql(request_fun, @update_comment_mutation, %{"id" => comment["id"], "body" => body}, settings),
         %{} = updated <- get_in(data, ["updateIssueComment", "issueComment"]) do
      {:ok, comment_evidence(updated, marker)}
    else
      false -> {:error, :github_agent_report_not_owned}
      nil -> {:error, :github_agent_identity_missing}
      {:error, _reason} = error -> error
      _ -> {:error, :github_agent_report_update_failed}
    end
  end

  defp replace_owned_comment_block(current, marker, end_marker, replacement) do
    with {start, _} <- :binary.match(current, marker),
         {finish, len} <- :binary.match(current, end_marker, scope: {start, byte_size(current) - start}) do
      prefix = binary_part(current, 0, start)
      suffix_start = finish + len
      suffix = binary_part(current, suffix_start, byte_size(current) - suffix_start)
      {:ok, prefix <> replacement <> suffix}
    else
      _ -> {:error, :github_agent_report_block_invalid}
    end
  end

  defp apply_project_status(_issue, _current, nil, _lane, _settings, _tracker_settings, _request_fun),
    do: {:ok, %{"updated" => false}}

  defp apply_project_status(issue, _current, target, lane, settings, tracker_settings, request_fun)
       when is_binary(target) do
    with {:ok, current} <- current_project_issue(issue, tracker_settings, request_fun),
         :ok <- handoff_source_status(lane, current, target, settings),
         current_status = project_status(current),
         :ok <- ensure_project_status(current, current_status, target, settings, request_fun),
         {:ok, verified} <- current_project_issue(issue, tracker_settings, request_fun),
         true <- project_status(verified) == target do
      {:ok, %{"id" => ref_value(verified.native_ref, :project_item_id), "status" => target, "updated" => current_status != target}}
    else
      false -> {:error, :github_project_transition_not_verified}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_project_status(_current, target, target, _settings, _request_fun), do: :ok

  defp ensure_project_status(current, _current_status, target, settings, request_fun),
    do: set_item_status(current.native_ref, target, settings, request_fun)

  defp current_project_issue(issue, tracker_settings, request_fun) do
    case fetch_issues_by_ids([issue.id], tracker_settings, request_fun) do
      {:ok, [current | _]} -> {:ok, current}
      {:ok, []} -> {:error, :github_project_item_missing}
      {:error, _reason} = error -> error
    end
  end

  defp claimable_project_status(dispatched, current, settings) do
    ready = normalize_state(settings.statuses.ready)
    building = normalize_state(settings.statuses.building)
    dispatched_status = normalize_state(ref_value(dispatched.native_ref || %{}, :project_status))
    current_status = normalize_state(project_status(current))

    if {dispatched_status, current_status} in [{ready, ready}, {ready, building}, {building, building}],
      do: :ok,
      else: {:error, :github_human_decision_changed}
  end

  defp expected_project_status(issue, statuses) do
    if project_status(issue) in statuses,
      do: :ok,
      else: {:error, :github_human_decision_changed}
  end

  defp maybe_set_project_status(current, target, settings, request_fun) do
    if project_status(current) == target,
      do: :ok,
      else: set_item_status(current.native_ref, target, settings, request_fun)
  end

  defp project_status(issue), do: ref_value(issue.native_ref, :project_status) || issue.state

  defp project_evidence(issue, current, status) do
    %{
      "issue" => %{"id" => issue.id, "url" => issue.url},
      "project_item" => %{"id" => ref_value(current.native_ref, :project_item_id), "status" => status}
    }
  end

  defp agent_report_marker(issue, context, phase) do
    phase_report_marker(issue, context[:generation] || 0, phase) <> ":#{context[:attempt] || 0} -->"
  end

  defp comment_evidence(comment, marker),
    do: %{"id" => comment["id"], "url" => comment["url"], "marker" => marker}

  defp pr_evidence(pr) do
    %{"id" => pr.id, "number" => pr.number, "url" => pr.url, "head_sha" => pr.sha, "base" => pr.base, "draft" => pr.draft, "merged" => pr.merged}
  end

  defp normalize_report(report) when is_map(report),
    do: Map.new(report, fn {key, value} -> {to_string(key), value} end)

  defp normalize_report(_report), do: %{}

  defp normalize_report_list(values) when is_list(values),
    do: Enum.map(values, &normalize_report/1)

  defp normalize_report_list(_values), do: []

  defp required_checks_passed?(required, checks) when is_list(required) and is_list(checks) do
    passed = MapSet.new(checks, fn check -> if check["status"] == "passed" and is_binary(check["evidence"]) and String.trim(check["evidence"]) != "", do: check["name"] end)
    Enum.all?(required, &MapSet.member?(passed, &1))
  end

  defp required_checks_passed?(_required, _checks), do: false

  defp delivery_body(report), do: PRBody.delivery_block(report["pull_request_body"])

  defp validate_merge_policy(nil), do: :ok
  defp validate_merge_policy(value) when value in ["human", "auto"], do: :ok
  defp validate_merge_policy(_value), do: invalid_settings(:invalid_merge_policy)

  defp request_merge(issue, context, tracker_settings, settings, request_fun, _opts) do
    task = Map.get(context, :task) || %{}
    branch = task["branch"] || issue.branch_name
    base = task["base_branch"] || Map.get(profile_for_issue(issue, settings), :base_branch)
    {owner, name} = split_repository(ref_value(issue.native_ref, :repository))
    variables = %{"owner" => owner, "name" => name, "branch" => branch, "base" => base, "baseRef" => "refs/heads/#{base}"}

    with true <- settings.merge_policy == "auto",
         true <- to_string(context.lane) == "review",
         :ok <- validate_agent_lease(context),
         {:ok, current} <- current_project_issue(issue, tracker_settings, request_fun),
         :ok <- expected_project_status(current, [settings.statuses.review, settings.statuses.human_review]),
         :ok <- ensure_merge_checks(task),
         {:ok, data} <- graphql(request_fun, @merge_query, variables, settings),
         %{} = pr <- find_pull_request(data, branch, base),
         :ok <- merge_gate(pr, task, get_in(data, ["repository", "ref", "target", "oid"])) do
      {:ok,
       %{
         "outcome" => "passed",
         "pull_request" => %{"head_sha" => pr["headRefOid"], "base_sha" => pr["baseRefOid"]},
         "sha" => task["current_sha"]
       }}
    else
      false -> {:error, :auto_merge_not_authorized}
      nil -> {:error, :pull_request_not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :merge_gate_failed}
    end
  end

  defp ensure_merge_checks(task) do
    required = task["required_checks"] || []
    checks = task["host_checks"] || []
    if required_checks_passed?(required, checks), do: :ok, else: {:error, :host_checks_not_verified}
  end

  defp find_pull_request(data, branch, base) do
    get_in(data, ["repository", "pullRequests", "nodes"])
    |> case do
      nodes when is_list(nodes) -> Enum.find(nodes, &(&1["headRefName"] == branch and &1["baseRefName"] == base))
      _ -> nil
    end
  end

  defp merge_gate(pr, task, current_base_sha) do
    head_sha = task["current_sha"]

    with :ok <- validate_merge_shas(head_sha, current_base_sha),
         :ok <- validate_merge_identity(pr, head_sha, current_base_sha),
         :ok <- validate_github_checks(pr) do
      validate_merge_state(pr)
    end
  end

  defp validate_merge_shas(head_sha, base_sha) do
    cond do
      not sha_available?(head_sha) -> {:error, :pull_request_head_sha_unavailable}
      not sha_available?(base_sha) -> {:error, :pull_request_base_sha_unavailable}
      true -> :ok
    end
  end

  defp validate_merge_identity(pr, head_sha, base_sha) do
    cond do
      pr["headRefOid"] != head_sha -> {:error, :pull_request_head_sha_mismatch}
      pr["baseRefOid"] != base_sha -> {:error, :pull_request_base_sha_mismatch}
      true -> :ok
    end
  end

  defp validate_github_checks(pr) do
    if get_in(pr, ["statusCheckRollup", "state"]) == "SUCCESS",
      do: :ok,
      else: {:error, :required_github_checks_not_passed}
  end

  defp validate_merge_state(pr) do
    cond do
      pr["state"] == "MERGED" and is_binary(pr["mergedAt"]) -> :ok
      pr["state"] == "OPEN" and pr["isDraft"] == false -> :ok
      true -> {:error, :pull_request_not_mergeable}
    end
  end

  defp sha_available?(sha), do: is_binary(sha) and sha != ""

  defp close_merged_issue(issue, settings, request_fun) do
    if issue.state == "closed" do
      {:ok, %{"id" => issue.id, "url" => issue.url, "state" => "CLOSED"}}
    else
      with issue_id when is_binary(issue_id) <- ref_value(issue.native_ref, :issue_node_id),
           {:ok, data} <- graphql(request_fun, @close_issue_mutation, %{"issueId" => issue_id}, settings),
           %{"state" => "CLOSED"} = closed <- get_in(data, ["closeIssue", "issue"]) do
        {:ok, %{"id" => closed["id"], "url" => closed["url"], "state" => closed["state"]}}
      else
        {:error, _reason} = error -> error
        _ -> {:error, :github_issue_close_not_confirmed}
      end
    end
  end

  defp perform_rest_request(method, path, params, body, settings) do
    case rest_method(method) do
      nil -> {:error, :invalid_github_method}
      request_method -> request_rest(request_method, path, params, body, settings)
    end
  end

  defp rest_method("GET"), do: :get
  defp rest_method("POST"), do: :post
  defp rest_method("PATCH"), do: :patch
  defp rest_method("PUT"), do: :put
  defp rest_method("DELETE"), do: :delete
  defp rest_method(_method), do: nil

  defp request_rest(method, path, params, body, settings) do
    request_opts = [
      method: method,
      url: github_rest_url(settings.graphql_url) <> path,
      headers: [
        {"Accept", "application/vnd.github+json"},
        {"Authorization", "Bearer #{settings.token}"},
        {"X-GitHub-Api-Version", "2022-11-28"},
        {"User-Agent", "symphony"}
      ],
      params: params,
      connect_options: [timeout: 30_000]
    ]

    request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

    case Req.request(request_opts) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp github_rest_url(graphql_url) do
    uri = URI.parse(graphql_url)
    path = if uri.path == "/graphql", do: "", else: String.replace_suffix(uri.path, "/graphql", "/v3")
    URI.to_string(%{uri | path: path, query: nil, fragment: nil})
  end

  defp create_follow_up_issue(issue, context, arguments, tracker_settings, settings, opts) do
    title = normalize_string(arguments["title"])
    body = normalize_string(arguments["body"])
    rest_fun = Keyword.get(opts, :github_rest, &perform_rest_request/5)

    with title when is_binary(title) and byte_size(title) <= 256 <- title,
         body when is_binary(body) and byte_size(body) <= 60_000 <- body,
         {:ok, repository} <- repository_for_issue(issue),
         marker = follow_up_marker(issue, context, title, body),
         {:ok, existing} <- find_follow_up_issue(repository, marker, settings, rest_fun),
         {:ok, follow_up} <-
           find_or_create_follow_up_issue(existing, repository, issue, title, body, marker, settings, rest_fun),
         :ok <- link_follow_up_issue(issue, follow_up, settings, rest_fun),
         {:ok, project_item} <- maybe_add_follow_up_to_project(follow_up, settings, tracker_settings, opts) do
      {:ok,
       %{
         "id" => "#{repository.owner}/#{repository.name}##{follow_up["number"]}",
         "number" => follow_up["number"],
         "url" => follow_up["url"],
         "parent" => issue.id,
         "linked" => true,
         "project_item" => project_item,
         "marker" => marker
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_follow_up_issue}
    end
  end

  defp find_or_create_follow_up_issue(%{} = existing, _repository, _issue, _title, _body, _marker, _settings, _rest_fun),
    do: {:ok, existing}

  defp find_or_create_follow_up_issue(nil, repository, issue, title, body, marker, settings, rest_fun),
    do: create_follow_up_issue_remote(repository, issue, title, body, marker, settings, rest_fun)

  defp follow_up_marker(issue, context, title, body) do
    digest = :crypto.hash(:sha256, title <> "\n" <> body) |> Base.encode16(case: :lower)
    "<!-- symphony:follow-up:#{issue.id}:#{context[:generation] || 0}:#{context[:lane]}:#{digest} -->"
  end

  defp find_follow_up_issue(repository, marker, settings, rest_fun) do
    query = "repo:#{repository.owner}/#{repository.name} in:body #{marker}"

    case rest_fun.("GET", "/search/issues", %{"q" => query, "per_page" => 10}, nil, settings) do
      {:ok, %{status: status, body: %{"items" => items}}} when status in 200..299 ->
        case Enum.find(items, &String.contains?(&1["body"] || "", marker)) do
          nil -> {:ok, nil}
          found -> {:ok, found}
        end

      {:ok, %{status: status}} ->
        {:error, {:github_follow_up_search_failed, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp create_follow_up_issue_remote(repository, parent, title, body, marker, settings, rest_fun) do
    path = "/repos/#{repository.owner}/#{repository.name}/issues"
    body = "#{body}\n\nParent: #{parent.url}\n\n#{marker}"

    case rest_fun.("POST", path, %{}, %{"title" => title, "body" => body}, settings) do
      {:ok, %{status: status, body: %{} = issue}} when status in 200..299 ->
        {:ok, issue}

      {:error, _reason} = error ->
        case find_follow_up_issue(repository, marker, settings, rest_fun) do
          {:ok, %{} = found} -> {:ok, found}
          _ -> error
        end

      {:ok, %{status: status}} ->
        {:error, {:github_follow_up_create_failed, status}}
    end
  end

  defp maybe_add_follow_up_to_project(follow_up, settings, tracker_settings, opts) do
    request_fun = Keyword.get(opts, :projects_request, &perform_request/3)

    with {:ok, project, metadata} <- project_for_link(settings, request_fun),
         :ok <- add_project_item_once(project, metadata, follow_up["node_id"], settings, request_fun) do
      with {:ok, issue} <- fetch_follow_up_project_issue(follow_up, tracker_settings, request_fun) do
        {:ok, %{"id" => ref_value(issue.native_ref, :project_item_id), "status" => project_status(issue)}}
      end
    end
  end

  defp link_follow_up_issue(parent, child, settings, rest_fun) do
    with {:ok, parent_ref} <- issue_repository_and_number(parent),
         child_id when is_integer(child_id) <- child["id"],
         path = "/repos/#{parent_ref["owner"]}/#{parent_ref["name"]}/issues/#{parent_ref["number"]}/sub_issues",
         {:ok, existing} <- rest_fun.("GET", path, %{"per_page" => @page_size}, nil, settings),
         true <- existing.status in 200..299 and is_list(existing.body) do
      linked? = Enum.any?(existing.body, &(to_string(&1["id"]) == to_string(child_id)))
      if linked?, do: :ok, else: create_follow_up_link(path, child_id, settings, rest_fun)
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_follow_up_link_failed}
    end
  end

  defp create_follow_up_link(path, child_id, settings, rest_fun) do
    case rest_fun.("POST", path, %{}, %{"sub_issue_id" => child_id}, settings) do
      {:ok, %{status: status}} when status in 200..299 ->
        verify_follow_up_link(path, child_id, settings, rest_fun)

      {:error, reason} ->
        if verify_follow_up_link(path, child_id, settings, rest_fun) == :ok,
          do: :ok,
          else: {:error, reason}

      _ ->
        {:error, :github_follow_up_link_failed}
    end
  end

  defp verify_follow_up_link(path, child_id, settings, rest_fun) do
    with {:ok, %{status: status, body: issues}} when status in 200..299 and is_list(issues) <-
           rest_fun.("GET", path, %{"per_page" => @page_size}, nil, settings),
         true <- Enum.any?(issues, &(to_string(&1["id"]) == to_string(child_id))) do
      :ok
    else
      {:error, _reason} = error -> error
      _ -> {:error, :github_follow_up_link_not_verified}
    end
  end

  defp project_for_link(settings, request_fun) do
    with {:ok, project} <- fetch_project(settings, request_fun, nil),
         {:ok, metadata} <- project_metadata(project, settings) do
      {:ok, project, metadata}
    end
  end

  defp add_project_item_once(project, _metadata, content_id, settings, request_fun) do
    items = get_in(project, ["items", "nodes"]) || []

    if Enum.any?(items, &(get_in(&1, ["content", "id"]) == content_id)) do
      :ok
    else
      with {:ok, data} <-
             graphql(request_fun, @add_project_item_mutation, %{"projectId" => project["id"], "contentId" => content_id}, settings),
           %{} <- get_in(data, ["addProjectV2ItemById", "item"]) do
        :ok
      else
        {:error, _reason} = error -> error
        _ -> {:error, :github_project_follow_up_link_failed}
      end
    end
  end

  defp fetch_follow_up_project_issue(follow_up, tracker_settings, request_fun) do
    id = "#{get_in(follow_up, ["repository", "nameWithOwner"])}##{follow_up["number"]}"

    case fetch_issues_by_ids([id], tracker_settings, request_fun) do
      {:ok, [issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, :github_follow_up_not_visible_in_project}
      {:error, _reason} = error -> error
    end
  end

  defp profile_for_issue(issue, settings) do
    case repository_for_issue(issue) do
      {:ok, repository} ->
        Map.get(settings.repositories, normalize_repository("#{repository.owner}/#{repository.name}"), %{})

      _ ->
        %{}
    end
  end

  defp ensure_pull_request_sha(%{sha: sha}, sha) when is_binary(sha), do: :ok
  defp ensure_pull_request_sha(_pr, _sha), do: {:error, :pull_request_head_sha_mismatch}

  # shortcut: Project status updates lack compare-and-set, upgrade when GitHub supports atomic conditional writes.
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

    with body when is_binary(body) and byte_size(body) in 1..60_000 <- attrs[:body],
         {:ok, data} <- graphql(request_fun, @repository_query, variables, settings),
         repository_id when is_binary(repository_id) <- get_in(data, ["repository", "id"]),
         input = %{
           "repositoryId" => repository_id,
           "baseRefName" => attrs.base,
           "headRefName" => attrs.branch,
           "title" => issue.title,
           "body" => body,
           "draft" => true
         },
         {:ok, created} <- graphql(request_fun, @create_pull_request_mutation, %{"input" => input}, settings),
         %{} = pr <- get_in(created, ["createPullRequest", "pullRequest"]) do
      {:ok, normalize_pull_request(pr)}
    else
      {:error, _reason} = error -> error
      body when not is_binary(body) -> {:error, :github_pull_request_body_required}
      body when is_binary(body) and byte_size(body) not in 1..60_000 -> {:error, :github_pull_request_body_required}
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
      base_sha: pr["baseRefOid"],
      branch: pr["headRefName"],
      sha: pr["headRefOid"],
      review_decision: pr["reviewDecision"],
      body: pr["body"]
    }
  end

  defp update_pull_request_body(pr, body, _settings, _request_fun) when not is_binary(body), do: {:ok, pr}

  defp update_pull_request_body(%{body: current} = pr, body, settings, request_fun) do
    case replace_delivery_block(current || "", body) do
      {:ok, ^current} ->
        {:ok, pr}

      {:ok, updated_body} ->
        with {:ok, data} <- graphql(request_fun, @update_pull_request_body_mutation, %{"pullRequestId" => pr.id, "body" => updated_body}, settings),
             %{} = updated <- get_in(data, ["updatePullRequest", "pullRequest"]) do
          {:ok, normalize_pull_request(updated)}
        else
          {:error, _reason} = error -> error
          _ -> {:error, {:github_projects_api_error, "Unable to update the pipeline pull request body."}}
        end
    end
  end

  defp replace_delivery_block(current, replacement) do
    start_marker = "<!-- symphony:delivery:start -->"
    end_marker = "<!-- symphony:delivery:end -->"

    case {:binary.match(current, start_marker), :binary.match(current, end_marker)} do
      {{start, _}, {finish, len}} when finish >= start ->
        suffix_start = finish + len
        prefix = binary_part(current, 0, start)
        suffix = binary_part(current, suffix_start, byte_size(current) - suffix_start)
        {:ok, prefix <> replacement <> suffix}

      _ when current == "" ->
        {:ok, replacement}

      _ ->
        {:ok, current}
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
         :ok <- validate_merge_policy(provider["merge_policy"]),
         :ok <- validate_pipeline_profiles(profiles),
         :ok <- validate_routing_settings(tracker_settings) do
      {:ok,
       Map.merge(project, %{
         statuses: @statuses,
         repositories: profiles,
         graphql_url: String.trim_trailing(graphql_url, "/"),
         token: token,
         merge_policy: provider["merge_policy"] || "human"
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
