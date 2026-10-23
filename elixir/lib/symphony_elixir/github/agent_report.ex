defmodule SymphonyElixir.GitHub.AgentReport do
  @moduledoc false

  @json_marker "<!-- symphony:report:json"
  @json_block ~r/<!-- symphony:report:json\n(.*?)\n-->/s
  @report_end "<!-- symphony:report:end -->"

  @doc false
  @spec validate_body(term(), map()) :: :ok | {:error, term()}
  def validate_body(body, report) when is_binary(body) and is_map(report) do
    cond do
      byte_size(body) not in 1..60_000 -> {:error, :invalid_github_agent_report_body}
      String.contains?(body, ["<!-- symphony:report:start:", @report_end]) -> {:error, :invalid_github_agent_report_body}
      true -> validate_json_block(body, report)
    end
  end

  def validate_body(_body, _report), do: {:error, :invalid_github_agent_report_body}

  @doc false
  @spec comment_body(String.t(), String.t()) :: String.t()
  def comment_body(marker, body), do: marker <> "\n" <> body <> "\n" <> @report_end

  @doc false
  @spec decode_comment(String.t()) :: {:ok, map()} | {:error, term()}
  def decode_comment(body) do
    case {json_marker_count(body), Regex.scan(@json_block, body, capture: :all_but_first)} do
      {1, [[json]]} -> decode_json_report(json)
      {0, []} -> decode_legacy_report(body)
      _ -> {:error, :invalid_phase_report}
    end
  end

  defp validate_json_block(body, report) do
    case {json_marker_count(body), Regex.scan(@json_block, body, capture: :all_but_first)} do
      {1, [[json]]} ->
        validate_json_report(body, json, report)

      {0, []} ->
        {:error, :missing_github_agent_report_json}

      _ ->
        {:error, :invalid_github_agent_report_json}
    end
  end

  defp validate_json_report(body, json, report) do
    if String.contains?(json, "-->") do
      {:error, :unsafe_github_agent_report_json}
    else
      validate_json_report_content(body, json, report)
    end
  end

  defp validate_json_report_content(body, json, report) do
    with {:ok, expected_json} <- Jason.encode(report),
         {:ok, expected} when is_map(expected) <- Jason.decode(expected_json),
         {:ok, actual} when is_map(actual) <- Jason.decode(json) do
      validate_decoded_report(body, actual, expected)
    else
      _ -> {:error, :invalid_github_agent_report_json}
    end
  end

  defp validate_decoded_report(body, actual, expected) do
    cond do
      actual != expected -> {:error, :github_agent_report_json_mismatch}
      visible_report_json?(body, expected) -> {:error, :visible_github_agent_report_json}
      true -> :ok
    end
  end

  defp decode_json_report(json) do
    case Jason.decode(json) do
      {:ok, report} when is_map(report) -> {:ok, report}
      _ -> {:error, :invalid_phase_report}
    end
  end

  defp decode_legacy_report(body) do
    json =
      body
      |> String.split("\n")
      |> Enum.drop_while(&(String.trim(&1) != "{"))
      |> Enum.take_while(&(String.trim(&1) != @report_end))
      |> Enum.join("\n")
      |> String.trim()

    case Jason.decode(json) do
      {:ok, report} when is_map(report) -> {:ok, report}
      _ -> {:error, :invalid_phase_report}
    end
  end

  defp visible_report_json?(body, expected) do
    visible = Regex.replace(@json_block, body, "")
    lines = String.split(visible, "\n")

    lines
    |> Enum.with_index()
    |> Enum.any?(&visible_json_report?(&1, lines, expected))
  end

  defp visible_json_report?({line, index}, lines, expected) do
    String.starts_with?(String.trim(line), "{") and json_report_from_lines?(lines, index, expected)
  end

  defp json_report_from_lines?(lines, index, expected) do
    lines
    |> Enum.drop(index)
    |> Enum.reduce_while("", fn next_line, candidate ->
      candidate = if candidate == "", do: next_line, else: candidate <> "\n" <> next_line

      case Jason.decode(String.trim(candidate)) do
        {:ok, report} -> {:halt, report == expected}
        _ -> {:cont, candidate}
      end
    end)
    |> Kernel.==(true)
  end

  defp json_marker_count(body), do: length(String.split(body, @json_marker)) - 1
end
