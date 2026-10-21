defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and provider-native agent tools.

  The orchestrator only depends on the read callbacks. Agent-side mutations stay
  behind optional provider-native tools so tracker-specific capabilities do not
  leak into scheduler policy.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @adapters %{
    "asana" => SymphonyElixir.Asana.Adapter,
    "github" => SymphonyElixir.GitHub.Adapter,
    "github_projects" => SymphonyElixir.GitHub.Projects.Adapter,
    "gitlab" => SymphonyElixir.GitLab.Adapter,
    "jira" => SymphonyElixir.Jira.Adapter,
    "linear" => SymphonyElixir.Linear.Adapter,
    "memory" => SymphonyElixir.Tracker.Memory
  }

  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback agent_tool_specs() :: [map()]
  @callback execute_agent_tool(String.t(), term(), keyword()) :: map()
  @callback secret_environment_names(map()) :: [String.t()]
  @callback validate_config(map()) :: :ok | {:error, term()}
  @callback claim_issue(Issue.t()) :: :ok | {:error, term()}
  @callback complete_issue(Issue.t()) :: :ok | {:error, term()}
  @callback block_issue(Issue.t(), String.t()) :: :ok | {:error, term()}
  @callback set_pipeline_status(Issue.t(), atom(), String.t() | nil) :: :ok | {:error, term()}
  @callback validate_pipeline_delivery(Issue.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback upsert_pull_request(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback set_pull_request_stage(Issue.t(), integer(), atom()) :: {:ok, map()} | {:error, term()}
  @callback pull_request(Issue.t()) :: {:ok, map() | nil} | {:error, term()}
  @callback publish_phase_report(Issue.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}

  @optional_callbacks agent_tool_specs: 0,
                      execute_agent_tool: 3,
                      validate_config: 1,
                      claim_issue: 1,
                      complete_issue: 1,
                      block_issue: 2,
                      set_pipeline_status: 3,
                      validate_pipeline_delivery: 3,
                      upsert_pull_request: 2,
                      set_pull_request_stage: 3,
                      pull_request: 1,
                      publish_phase_report: 4

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    adapter().fetch_issues_by_ids(issue_ids)
  end

  @spec claim_issue(Issue.t()) :: :ok | :ignore | {:error, term()}
  def claim_issue(%Issue{} = issue), do: issue_lifecycle_callback(:claim_issue, [issue])

  @spec complete_issue(Issue.t()) :: :ok | :ignore | {:error, term()}
  def complete_issue(%Issue{} = issue), do: issue_lifecycle_callback(:complete_issue, [issue])

  @spec block_issue(Issue.t(), String.t()) :: :ok | :ignore | {:error, term()}
  def block_issue(%Issue{} = issue, reason) when is_binary(reason),
    do: issue_lifecycle_callback(:block_issue, [issue, reason])

  @spec set_pipeline_status(Issue.t(), atom(), String.t() | nil) :: :ok | :ignore | {:error, term()}
  def set_pipeline_status(%Issue{} = issue, status, reason \\ nil),
    do: issue_lifecycle_callback(:set_pipeline_status, [issue, status, reason])

  @spec validate_pipeline_delivery(Issue.t(), String.t(), String.t()) :: :ok | :ignore | {:error, term()}
  def validate_pipeline_delivery(%Issue{} = issue, branch, sha),
    do: issue_lifecycle_callback(:validate_pipeline_delivery, [issue, branch, sha])

  @spec upsert_pull_request(Issue.t(), map()) :: {:ok, map()} | :ignore | {:error, term()}
  def upsert_pull_request(%Issue{} = issue, attrs),
    do: issue_lifecycle_callback(:upsert_pull_request, [issue, attrs])

  @spec set_pull_request_stage(Issue.t(), integer(), atom()) :: {:ok, map()} | :ignore | {:error, term()}
  def set_pull_request_stage(%Issue{} = issue, number, stage),
    do: issue_lifecycle_callback(:set_pull_request_stage, [issue, number, stage])

  @spec pull_request(Issue.t()) :: {:ok, map() | nil} | :ignore | {:error, term()}
  def pull_request(%Issue{} = issue), do: issue_lifecycle_callback(:pull_request, [issue])

  @spec publish_phase_report(Issue.t(), String.t(), String.t(), String.t()) :: :ok | :ignore | {:error, term()}
  def publish_phase_report(%Issue{} = issue, marker, body, phase),
    do: issue_lifecycle_callback(:publish_phase_report, [issue, marker, body, phase])

  @doc """
  Captures the selected adapter and effective tracker settings for one
  app-server session so tool advertisement and execution cannot drift across a
  workflow reload.
  """
  @spec bind_agent_tools() :: map()
  def bind_agent_tools do
    tracker_settings = Config.settings!().tracker
    adapter = adapter_for_settings!(tracker_settings)

    %{
      adapter: adapter,
      tracker_settings: tracker_settings,
      tool_specs: adapter_agent_tool_specs(adapter),
      secret_environment_names: adapter_secret_environment_names(adapter, tracker_settings)
    }
  end

  @spec execute_bound_agent_tool(map(), String.t(), term(), keyword()) :: map()
  def execute_bound_agent_tool(
        %{adapter: adapter, tracker_settings: tracker_settings},
        tool,
        arguments,
        opts \\ []
      ) do
    execute_agent_tool_with_adapter(
      adapter,
      tool,
      arguments,
      Keyword.put(opts, :tracker_settings, tracker_settings)
    )
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :validate_config, 1) do
        adapter.validate_config(tracker_settings)
      else
        :ok
      end
    end
  end

  @spec adapter() :: module()
  def adapter do
    Config.settings!().tracker
    |> adapter_for_settings!()
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  defp adapter_for_settings!(%{kind: kind}) do
    {:ok, adapter} = adapter_for_kind(kind)
    adapter
  end

  defp adapter_agent_tool_specs(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :agent_tool_specs, 0) do
      adapter.agent_tool_specs()
    else
      []
    end
  end

  defp execute_agent_tool_with_adapter(adapter, tool, arguments, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(tool, arguments, opts)
    else
      unsupported_agent_tool_response(tool)
    end
  end

  defp adapter_secret_environment_names(adapter, tracker_settings) do
    adapter.secret_environment_names(tracker_settings)
  end

  defp issue_lifecycle_callback(callback, arguments) do
    adapter = adapter()

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, callback, length(arguments)) do
      apply(adapter, callback, arguments)
    else
      :ignore
    end
  end

  defp unsupported_agent_tool_response(tool) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
