defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized work item representation used by the orchestrator.

  `id` is the stable dispatch identity for the configured tracker scope. It may
  differ from a provider's underlying issue ID when the scheduled item is a
  board or project entry. `native_ref` carries non-secret provider identifiers
  needed by provider-native agent tools. `execution_identity/1` names workspaces
  and artifacts; `identifier` remains the human-readable value used by the UI.
  """

  defstruct [
    :id,
    :native_ref,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    requeueable: false,
    tracker_blocked: false,
    blocked_by: [],
    labels: [],
    dispatchable: false,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          native_ref: map() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          requeueable: boolean(),
          tracker_blocked: boolean(),
          labels: [String.t()],
          blocked_by: [map()],
          dispatchable: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec execution_identity(t()) :: String.t()
  def execution_identity(%__MODULE__{} = issue) do
    ref = issue.native_ref || %{}
    project_id = native_ref_value(ref, :project_id)
    project_item_id = native_ref_value(ref, :project_item_id)
    repository = native_ref_value(ref, :repository)
    issue_number = native_ref_value(ref, :issue_number)

    if present?(project_id) and present?(project_item_id) and present?(repository) and
         (is_integer(issue_number) or present?(issue_number)) do
      "#{project_id}/#{project_item_id}/#{repository}##{issue_number}"
    else
      issue.identifier || issue.id || "issue"
    end
  end

  @spec routable?(t(), [String.t()]) :: boolean()
  def routable?(%__MODULE__{dispatchable: true, labels: labels}, required_labels)
      when is_list(labels) and is_list(required_labels) do
    issue_labels = MapSet.new(labels, &normalize_label/1)
    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  def routable?(%__MODULE__{}, _required_labels), do: false

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp native_ref_value(ref, key), do: Map.get(ref, key) || Map.get(ref, Atom.to_string(key))
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
