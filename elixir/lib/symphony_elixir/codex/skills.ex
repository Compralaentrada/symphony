defmodule SymphonyElixir.Codex.Skills do
  @moduledoc """
  Selects repo-local skills for a work item and checks that Codex can discover them.
  """

  alias SymphonyElixir.{PathSafety, Tracker.Issue}

  @code_skills ["ponytail", "tdd"]
  @frontend_labels ["frontend", "front-end", "ui"]
  @writing_labels ["copywriting", "customer-facing", "humanizer", "user-facing"]

  @spec select(Issue.t()) :: [String.t()]
  def select(%Issue{labels: labels}) when is_list(labels) do
    labels =
      labels
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> MapSet.new()

    code_skills = if MapSet.member?(labels, "writing-only") or MapSet.member?(labels, "text-only"), do: [], else: @code_skills
    frontend_skill = if Enum.any?(@frontend_labels, &MapSet.member?(labels, &1)), do: ["impeccable"], else: []
    writing_skill = if Enum.any?(@writing_labels, &MapSet.member?(labels, &1)), do: ["humanizer"], else: []

    Enum.uniq(code_skills ++ ["code-review"] ++ frontend_skill ++ writing_skill)
  end

  def select(%Issue{}), do: ["ponytail", "tdd", "code-review"]

  @spec ensure_available(Path.t(), Issue.t()) :: :ok | {:error, {:required_skill_unavailable, String.t(), Path.t()}}
  def ensure_available(workspace, %Issue{} = issue) when is_binary(workspace) do
    case PathSafety.canonicalize(workspace) do
      {:ok, canonical_workspace} ->
        case Enum.find(select(issue), &(not skill_available?(workspace, canonical_workspace, &1))) do
          nil -> :ok
          skill -> {:error, {:required_skill_unavailable, skill, skill_path(workspace, skill)}}
        end

      {:error, reason} ->
        {:error, {:skill_workspace_unavailable, workspace, reason}}
    end
  end

  defp skill_available?(workspace, canonical_workspace, skill) do
    skill_path = skill_path(workspace, skill)

    with true <- File.regular?(skill_path),
         {:ok, canonical_skill_path} <- PathSafety.canonicalize(skill_path) do
      String.starts_with?(canonical_skill_path <> "/", canonical_workspace <> "/")
    else
      _reason -> false
    end
  end

  defp skill_path(workspace, skill), do: Path.join([workspace, ".agents", "skills", skill, "SKILL.md"])
end
