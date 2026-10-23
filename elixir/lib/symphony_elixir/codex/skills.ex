defmodule SymphonyElixir.Codex.Skills do
  @moduledoc """
  Selects fixed, phase-aware skills for a work item and checks their availability.
  """

  alias SymphonyElixir.{PathSafety, Tracker.Issue}

  @code_skills ["ponytail"]
  @phase_skills %{build: ["ponytail"], qa: [], review: []}
  @skill_free_phases [:diagnostic, :finalize]
  @writing_only_labels ["writing-only", "text-only"]
  @writing_labels ["copywriting", "customer-facing", "humanizer", "user-facing"]

  @spec select(Issue.t()) :: [String.t()]
  def select(%Issue{} = issue) do
    labels = normalized_labels(issue)

    Enum.uniq(selected_code_skills(labels, @code_skills) ++ ["code-review"] ++ humanizer_skills(labels))
  end

  @spec select(Issue.t(), atom() | nil) :: [String.t()]
  def select(%Issue{} = issue, phase) when is_map_key(@phase_skills, phase) do
    labels = normalized_labels(issue)

    Enum.uniq(selected_code_skills(labels, @phase_skills[phase]) ++ humanizer_skills(labels))
  end

  def select(%Issue{}, phase) when phase in @skill_free_phases, do: []
  def select(%Issue{} = issue, nil), do: select(issue)
  def select(%Issue{}, _phase), do: []

  defp selected_code_skills(labels, skills) do
    if Enum.any?(@writing_only_labels, &Enum.member?(labels, &1)), do: [], else: skills
  end

  defp humanizer_skills(labels) do
    if Enum.any?(@writing_labels, &Enum.member?(labels, &1)), do: ["humanizer"], else: []
  end

  @spec ensure_available(Path.t(), Issue.t()) :: :ok | {:error, {:required_skill_unavailable, String.t(), Path.t()}}
  def ensure_available(workspace, %Issue{} = issue), do: ensure_available(workspace, issue, nil)

  @spec ensure_available(Path.t(), Issue.t(), atom() | nil) ::
          :ok | {:error, {:required_skill_unavailable, String.t(), Path.t()}}
  def ensure_available(workspace, %Issue{} = issue, phase) when is_binary(workspace) do
    case PathSafety.canonicalize(workspace) do
      {:ok, canonical_workspace} ->
        skills = if is_nil(phase), do: select(issue), else: select(issue, phase)

        case Enum.find(skills, &(not skill_available?(workspace, canonical_workspace, &1))) do
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

  @spec normalized_labels(Issue.t()) :: [String.t()]
  defp normalized_labels(%Issue{labels: labels}) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.uniq()
  end

  defp normalized_labels(%Issue{}), do: []

  defp skill_path(workspace, skill), do: Path.join([workspace, ".agents", "skills", skill, "SKILL.md"])
end
