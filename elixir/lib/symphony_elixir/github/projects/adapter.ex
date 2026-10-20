defmodule SymphonyElixir.GitHub.Projects.Adapter do
  @moduledoc """
  GitHub Projects v2-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, GitHub.AgentTool, GitHub.Projects.Client}
  alias SymphonyElixir.Tracker.Issue

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings), do: Client.validate_settings(tracker_settings)

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec claim_issue(Issue.t()) :: :ok | {:error, term()}
  def claim_issue(issue), do: client_module().claim_issue(issue)

  @spec complete_issue(Issue.t()) :: :ok | {:error, term()}
  def complete_issue(issue), do: client_module().complete_issue(issue)

  @spec block_issue(Issue.t(), String.t()) :: :ok | {:error, term()}
  def block_issue(issue, reason), do: client_module().block_issue(issue, reason)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    provider = tracker_settings.provider

    default_repo =
      provider
      |> Map.get("repositories", [])
      |> List.first()
      |> case do
        %{"repository" => repository} -> repository
        _ -> nil
      end

    tracker_settings = %{
      tracker_settings
      | provider: Map.put_new(provider, "repo", default_repo)
    }

    AgentTool.execute(tool, arguments, Keyword.put(opts, :tracker_settings, tracker_settings))
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings),
    do: Client.secret_environment_names(tracker_settings)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_projects_client_module, Client)
  end
end
