defmodule SymphonyElixir.Codex.Skills do
  @moduledoc """
  Selects fixed, phase-aware skills and checks their content against the app lock.
  """

  alias SymphonyElixir.{PathSafety, Tracker.Issue, Workspace}

  @catalog_path Path.expand("../../../priv/skills/catalog.lock.json", __DIR__)
  @external_resource @catalog_path
  @catalog @catalog_path |> File.read!() |> Jason.decode!()

  @code_skills ["ponytail"]
  @phase_skills %{build: ["ponytail", "tdd-autonomous"], qa: [], review: []}
  @skill_free_phases [:diagnostic, :finalize]
  @snapshot_phases [:build, :qa, :review, :diagnostic, :finalize]
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

  @spec effective_config(Issue.t()) :: map()
  def effective_config(%Issue{} = issue) do
    %{
      "skills" =>
        Map.new(@snapshot_phases, fn phase ->
          {Atom.to_string(phase), snapshot_for_phase(issue, phase)}
        end)
    }
  end

  @spec snapshot_for_phase(Issue.t(), atom() | String.t() | nil) :: [map()]
  def snapshot_for_phase(%Issue{} = issue, phase) do
    phase_skills =
      case phase do
        nil -> select(issue)
        phase when is_atom(phase) -> select(issue, phase)
        phase when phase in ["build", "qa", "review", "diagnostic", "finalize"] -> select(issue, String.to_existing_atom(phase))
        _ -> []
      end

    Enum.map(phase_skills, fn skill -> Map.fetch!(@catalog, skill) |> Map.put("name", skill) end)
  end

  @spec attempt_snapshot(Issue.t(), map() | nil, atom() | String.t() | nil) :: [map()]
  def attempt_snapshot(%Issue{} = issue, task, phase) do
    phase = if is_atom(phase) and not is_nil(phase), do: Atom.to_string(phase), else: phase

    case get_in(task || %{}, ["effective_config", "skills", phase]) do
      snapshot when is_list(snapshot) -> snapshot
      _ -> snapshot_for_phase(issue, phase)
    end
  end

  @spec names([map()]) :: [String.t()]
  def names(snapshot), do: Enum.map(snapshot, & &1["name"])

  @spec ensure_available(Path.t(), Issue.t()) :: :ok | {:error, term()}
  def ensure_available(workspace, %Issue{} = issue), do: verify_snapshot(workspace, snapshot_for_phase(issue, nil))

  @spec ensure_available(Path.t(), Issue.t(), atom() | nil) :: :ok | {:error, term()}
  def ensure_available(workspace, %Issue{} = issue, phase),
    do: verify_snapshot(workspace, snapshot_for_phase(issue, phase))

  @spec verify_snapshot(Path.t(), [map()]) :: :ok | {:error, term()}
  def verify_snapshot(workspace, snapshot) when is_binary(workspace) and is_list(snapshot) do
    case PathSafety.canonicalize(workspace) do
      {:ok, canonical_workspace} ->
        with :ok <- verify_skill_paths(workspace, canonical_workspace, snapshot) do
          Workspace.verify_skill_snapshot(workspace, snapshot, nil)
        end

      {:error, reason} ->
        {:error, {:skill_workspace_unavailable, workspace, reason}}
    end
  end

  defp verify_skill_paths(workspace, canonical_workspace, snapshot) do
    Enum.reduce_while(snapshot, :ok, fn
      %{"name" => skill}, :ok when is_binary(skill) ->
        result =
          if Map.has_key?(@catalog, skill),
            do: verify_skill_path(workspace, canonical_workspace, skill),
            else: {:error, {:invalid_skill_snapshot, skill}}

        case result do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      skill, :ok ->
        {:halt, {:error, {:invalid_skill_snapshot, skill}}}
    end)
  end

  defp verify_skill_path(workspace, canonical_workspace, skill) do
    skill_path = skill_path(workspace, skill)
    checksum_path = Path.join(Path.dirname(skill_path), "CHECKSUMS.sha256")

    with true <- File.regular?(skill_path),
         {:ok, canonical_skill_path} <- PathSafety.canonicalize(skill_path),
         true <- inside?(canonical_skill_path, canonical_workspace),
         {:ok, canonical_skill_dir} <- PathSafety.canonicalize(Path.dirname(skill_path)),
         true <- inside?(canonical_skill_dir, canonical_workspace),
         true <- File.regular?(checksum_path),
         {:ok, canonical_checksum_path} <- PathSafety.canonicalize(checksum_path),
         true <- inside?(canonical_checksum_path, canonical_skill_dir) do
      :ok
    else
      _reason -> {:error, {:required_skill_unavailable, skill, skill_path}}
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path <> "/", root <> "/")

  defp selected_code_skills(labels, skills) do
    if Enum.any?(@writing_only_labels, &Enum.member?(labels, &1)), do: [], else: skills
  end

  defp humanizer_skills(labels) do
    if Enum.any?(@writing_labels, &Enum.member?(labels, &1)), do: ["humanizer"], else: []
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
