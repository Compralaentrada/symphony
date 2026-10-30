defmodule SymphonyElixir.QAReport do
  @moduledoc false

  @statuses ~w(passed failed unstable skipped unavailable)
  @layers ~w(unit component e2e manual)
  @priorities ~w(high medium low)

  def valid?(report, required_host_checks \\ [], issue_description \\ nil)

  @spec valid?(map(), [String.t()], String.t() | nil) :: boolean()
  def valid?(report, required_host_checks, issue_description)
      when is_map(report) and is_list(required_host_checks) and
             (is_binary(issue_description) or is_nil(issue_description)) do
    checks = report["checks"]
    host_checks = Map.get(report, "host_checks", report["_host_checks"])

    valid_checks?(checks) and valid_host_checks?(host_checks) and valid_delivery?(report, checks, host_checks) and
      valid_criteria?(report["criteria"], checks, host_checks, criteria_from_description(issue_description)) and
      valid_gaps?(report["gaps"]) and
      valid_outcome?(report, checks, host_checks, required_host_checks)
  end

  def valid?(_report, _required_host_checks, _issue_description), do: false

  defp valid_delivery?(report, checks, host_checks) do
    valid_files?(report["files"]) and valid_verification_command?(report["verification_command"], checks, host_checks) and
      valid_verification_result?(report, checks, host_checks)
  end

  defp valid_verification_result?(%{"outcome" => "passed"} = report, checks, host_checks) do
    command = report["verification_command"]

    Enum.any?(checks, &(&1["command"] == command and &1["status"] == "passed")) or
      (is_list(host_checks) and Enum.any?(host_checks, &(&1["name"] == command and &1["status"] == "passed" and &1["source"] == "host")))
  end

  defp valid_verification_result?(_report, _checks, _host_checks), do: true

  @spec criteria_from_description(String.t() | nil) :: [String.t()] | nil
  def criteria_from_description(description) when is_binary(description) do
    case Enum.drop_while(String.split(description, "\n"), &(not acceptance_heading?(&1))) do
      [] ->
        nil

      [_heading | section] ->
        section
        |> Enum.take_while(&(not markdown_heading?(&1)))
        |> criteria_from_lines()
    end
  end

  def criteria_from_description(_description), do: nil

  defp criteria_from_lines(lines) do
    lines
    |> Enum.reduce([], &append_criterion_line/2)
    |> Enum.reverse()
    |> Enum.chunk_by(&(parse_criterion(&1) != []))
    |> Enum.flat_map(&criteria_from_chunk/1)
  end

  defp append_criterion_line(line, [previous | rest] = acc) do
    if Regex.match?(~r/^[ \t]+\S/u, line) and parse_criterion(line) == [] and parse_criterion(previous) != [] do
      [previous <> " " <> String.trim(line) | rest]
    else
      [line | acc]
    end
  end

  defp append_criterion_line(line, []), do: [line]

  defp criteria_from_chunk(chunk) do
    case Enum.flat_map(chunk, &parse_criterion/1) do
      [] -> prose_criteria(chunk)
      criteria -> criteria
    end
  end

  defp prose_criteria(lines) do
    lines
    |> Enum.chunk_by(&(String.trim(&1) == ""))
    |> Enum.reject(&(String.trim(hd(&1)) == ""))
    |> Enum.map(fn paragraph -> Enum.map_join(paragraph, " ", &String.trim/1) end)
  end

  defp parse_criterion(line) do
    case Regex.run(~r/^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?(.+?)\s*$/, line) do
      [_, criterion] -> [String.trim(criterion)]
      _ -> []
    end
  end

  defp acceptance_heading?(line) do
    heading =
      line
      |> String.trim()
      |> String.trim_leading("#")
      |> String.trim()
      |> String.trim_trailing("#")
      |> String.trim()
      |> String.trim_trailing(":")
      |> String.downcase()
      |> String.replace("ó", "o")

    heading in ["acceptance criteria", "criterios de aceptacion", "aceptacion"]
  end

  defp markdown_heading?(line), do: String.starts_with?(String.trim(line), "#")

  defp valid_checks?(checks) when is_list(checks) do
    Enum.all?(checks, &valid_check?/1) and
      length(checks) == MapSet.size(MapSet.new(checks, & &1["id"]))
  end

  defp valid_checks?(_checks), do: false

  defp valid_files?(files) when is_list(files) do
    Enum.all?(files, fn
      %{"path" => path, "change" => change} ->
        present?(path) and not String.starts_with?(path, "/") and
          Enum.all?(Path.split(path), &(&1 not in [".", "..", ""])) and change in ["added", "modified"]

      _ ->
        false
    end) and length(files) == MapSet.size(MapSet.new(files, & &1["path"]))
  end

  defp valid_files?(_files), do: false

  defp valid_verification_command?(command, checks, host_checks) when is_binary(command) and is_list(checks) do
    present?(command) and
      (Enum.any?(checks, &(&1["command"] == command)) or
         (is_list(host_checks) and Enum.any?(host_checks, &(&1["name"] == command and &1["source"] == "host"))))
  end

  defp valid_verification_command?(_command, _checks, _host_checks), do: false

  defp valid_check?(%{
         "id" => id,
         "layer" => layer,
         "command" => command,
         "status" => status,
         "result" => result,
         "evidence" => evidence,
         "required" => required,
         "reason" => reason
       }) do
    present?(id) and layer in @layers and valid_command?(layer, command) and status in @statuses and
      present?(result) and present?(evidence) and is_boolean(required) and valid_reason?(status, reason)
  end

  defp valid_check?(_check), do: false

  defp valid_command?("manual", command), do: is_nil(command) or present?(command)
  defp valid_command?(_layer, command), do: present?(command)

  defp valid_reason?(status, reason) when status in ["skipped", "unstable", "unavailable"], do: present?(reason)
  defp valid_reason?(_status, reason), do: is_nil(reason) or present?(reason)

  defp valid_host_checks?(nil), do: true

  defp valid_host_checks?(checks) when is_list(checks) do
    Enum.all?(checks, fn
      %{"name" => name, "status" => status, "evidence" => evidence, "source" => "host"} = check ->
        present?(name) and status in @statuses and present?(evidence) and valid_reason?(status, check["reason"])

      _ ->
        false
    end)
  end

  defp valid_host_checks?(_checks), do: false

  defp valid_criteria?(criteria, checks, host_checks, expected_criteria) when is_list(criteria) and is_list(checks) do
    checks_by_id = Map.new(checks, &{&1["id"], &1["status"]})

    Enum.all?(criteria, fn
      %{"criterion" => criterion, "status" => status, "procedure" => procedure, "evidence" => evidence}
      when status in @statuses and is_list(evidence) and evidence != [] ->
        present?(criterion) and present?(procedure) and Enum.all?(evidence, &present?/1) and
          evidence
          |> Enum.map(&evidence_status(&1, checks_by_id, host_checks))
          |> status_matches?(status)

      _ ->
        false
    end) and criteria_match?(criteria, expected_criteria)
  end

  defp valid_criteria?(_criteria, _checks, _host_checks, _expected_criteria), do: false

  defp criteria_match?(_criteria, nil), do: true

  defp criteria_match?(criteria, expected) when is_list(expected) do
    actual = Enum.map(criteria, &normalize_criterion(&1["criterion"]))
    Enum.sort(actual) == Enum.sort(Enum.map(expected, &normalize_criterion/1))
  end

  defp normalize_criterion(value), do: value |> String.trim() |> String.replace(~r/\s+/u, " ") |> String.downcase()

  defp evidence_status(reference, checks_by_id, host_checks) do
    case Map.fetch(checks_by_id, reference) do
      {:ok, status} -> status
      :error -> host_evidence_status(reference, host_checks)
    end
  end

  defp host_evidence_status("host:" <> command, nil) when command != "", do: :deferred

  defp host_evidence_status("host:" <> command, checks) when command != "" and is_list(checks) do
    case Enum.find(checks, &(&1["name"] == command and &1["source"] == "host")) do
      %{"status" => status} -> status
      nil -> :missing
    end
  end

  defp host_evidence_status(_reference, _checks), do: :missing

  defp status_matches?(statuses, "passed"), do: Enum.all?(statuses, &(&1 in ["passed", :deferred]))
  defp status_matches?(statuses, status), do: Enum.any?(statuses, &(&1 in [status, :deferred]))

  defp valid_gaps?(gaps) when is_list(gaps) do
    Enum.all?(gaps, fn
      %{"scenario" => scenario, "impact" => impact, "missing_coverage" => missing, "priority" => priority} ->
        present?(scenario) and present?(impact) and present?(missing) and priority in @priorities

      _ ->
        false
    end) and Enum.map(gaps, &priority_rank(&1["priority"])) == Enum.sort(Enum.map(gaps, &priority_rank(&1["priority"])))
  end

  defp valid_gaps?(_gaps), do: false

  defp required_check_unavailable?(checks) when is_list(checks),
    do: Enum.any?(checks, &(&1["required"] and &1["status"] == "unavailable"))

  defp priority_rank("high"), do: 0
  defp priority_rank("medium"), do: 1
  defp priority_rank("low"), do: 2

  defp valid_outcome?(report, checks, host_checks, required_host_checks) do
    case report["outcome"] do
      "passed" -> passable?(report, checks, host_checks, required_host_checks)
      "blocked" -> present?(report["reason"]) and present?(report["next_step"])
      _ -> not required_check_unavailable?(checks)
    end
  end

  defp passable?(report, checks, host_checks, required_host_checks) do
    criteria_passed?(report) and required_checks_passed?(checks) and no_findings?(report) and
      required_host_checks_passed?(host_checks, required_host_checks)
  end

  defp criteria_passed?(report), do: is_list(report["criteria"]) and Enum.all?(report["criteria"], &(&1["status"] == "passed"))
  defp required_checks_passed?(checks), do: Enum.all?(checks, &(not &1["required"] or &1["status"] == "passed"))
  defp no_findings?(report), do: is_list(report["findings"]) and report["findings"] == []

  defp required_host_checks_passed?(host_checks, required_host_checks) do
    Enum.all?(required_host_checks, fn command ->
      is_list(host_checks) and
        Enum.any?(host_checks, &(&1["name"] == command and &1["status"] == "passed" and present?(&1["evidence"])))
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
