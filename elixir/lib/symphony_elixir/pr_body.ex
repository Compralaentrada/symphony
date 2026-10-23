defmodule SymphonyElixir.PRBody do
  @moduledoc false

  @template_path Path.expand("../../../.github/pull_request_template.md", __DIR__)
  @external_resource @template_path
  @template File.read!(@template_path)
  @delivery_start "<!-- symphony:delivery:start -->"
  @delivery_end "<!-- symphony:delivery:end -->"

  @spec validate_agent_body(term(), term()) :: :ok | {:error, :invalid_github_pull_request_body}
  def validate_agent_body(body, issue_id) when is_binary(body) and is_binary(issue_id) do
    errors =
      if byte_size(body) in 1..60_000 and not String.contains?(body, [@delivery_start, @delivery_end]) do
        lint(@template, body) ++ exact_issue_reference_errors(body, issue_id)
      else
        ["PR body is empty, too long, or includes Symphony delivery markers."]
      end

    if errors == [], do: :ok, else: {:error, :invalid_github_pull_request_body}
  end

  def validate_agent_body(_body, _issue_id), do: {:error, :invalid_github_pull_request_body}

  @spec delivery_block(String.t()) :: String.t()
  def delivery_block(body) when is_binary(body) do
    @delivery_start <> "\n" <> String.trim(body) <> "\n" <> @delivery_end
  end

  @spec lint(term(), term()) :: [String.t()]
  def lint(template, body) when is_binary(template) and is_binary(body) do
    headings = Regex.scan(~r/^\#{4,6}\s+.+$/m, template) |> Enum.map(&hd/1)

    case unwrap_delivery_markers(body) do
      {:ok, body} ->
        errors = if headings == [], do: ["No markdown headings found in PR template."], else: []

        errors
        |> check_required_headings(body, headings)
        |> check_order(body, headings)
        |> check_no_placeholders(body)
        |> check_issue_reference(body)
        |> check_sections_from_template(template, body, headings)

      {:error, message} ->
        [message]
    end
  end

  def lint(_template, _body), do: ["PR template and body must be Markdown strings."]

  defp exact_issue_reference_errors(body, issue_id) do
    case Regex.run(~r/#([1-9][0-9]*)$/, issue_id) do
      [_, number] ->
        if Enum.any?(String.split(body, "\n"), &(&1 == "Fixes ##{number}")),
          do: [],
          else: ["Build PR body must contain `Fixes ##{number}` for its issue."]

      _ ->
        ["Build PR issue identifier is invalid."]
    end
  end

  defp unwrap_delivery_markers(body) do
    start_count = length(String.split(body, @delivery_start)) - 1
    end_count = length(String.split(body, @delivery_end)) - 1

    case {start_count, end_count} do
      {0, 0} ->
        {:ok, body}

      {1, 1} ->
        with {start, _} <- :binary.match(body, @delivery_start),
             {finish, _} when finish > start <-
               :binary.match(body, @delivery_end) do
          cleaned_body =
            body
            |> String.replace(@delivery_start, "", global: false)
            |> String.replace(@delivery_end, "", global: false)

          {:ok, cleaned_body}
        else
          _ -> {:error, "Symphony delivery markers are out of order."}
        end

      _ ->
        {:error, "PR body must contain one matching pair of Symphony delivery markers."}
    end
  end

  defp check_required_headings(errors, body, headings) do
    missing = Enum.filter(headings, fn heading -> heading_position(body, heading) == :nomatch end)
    errors ++ Enum.map(missing, fn heading -> "Missing required heading: #{heading}" end)
  end

  defp check_order(errors, body, headings) do
    positions = headings |> Enum.map(&heading_position(body, &1)) |> Enum.reject(&(&1 == :nomatch))
    if positions == Enum.sort(positions), do: errors, else: errors ++ ["Required headings are out of order."]
  end

  defp check_no_placeholders(errors, body) do
    if String.contains?(body, "<!--"),
      do: errors ++ ["PR description still contains template placeholder comments (<!-- ... -->)."],
      else: errors
  end

  defp check_issue_reference(errors, body) do
    if Regex.match?(~r/^\s*(?:Fixes|Closes|Resolves|Related to) #[1-9][0-9]*\s*$/mi, body),
      do: errors,
      else: errors ++ ["Include Fixes, Closes, Resolves, or Related to #<number>."]
  end

  defp check_sections_from_template(errors, template, body, headings) do
    Enum.reduce(headings, errors, fn heading, acc ->
      template_section = capture_heading_section(template, heading, headings)
      body_section = capture_heading_section(body, heading, headings)

      cond do
        is_nil(body_section) ->
          acc

        String.trim(body_section) == "" ->
          acc ++ ["Section cannot be empty: #{heading}"]

        true ->
          acc
          |> maybe_require_bullets(heading, template_section, body_section)
          |> maybe_require_checkboxes(heading, template_section, body_section)
      end
    end)
  end

  defp maybe_require_bullets(errors, heading, template_section, body_section) do
    requires_bullets = Regex.match?(~r/^- /m, template_section || "")

    if requires_bullets and not Regex.match?(~r/^- /m, body_section),
      do: errors ++ ["Section must include at least one bullet item: #{heading}"],
      else: errors
  end

  defp maybe_require_checkboxes(errors, heading, template_section, body_section) do
    requires_checkboxes = Regex.match?(~r/^- \[ \] /m, template_section || "")

    if requires_checkboxes and not Regex.match?(~r/^- \[[ xX]\] /m, body_section),
      do: errors ++ ["Section must include at least one checkbox item: #{heading}"],
      else: errors
  end

  defp heading_position(body, heading) do
    case :binary.match(body, heading) do
      {idx, _len} -> idx
      :nomatch -> :nomatch
    end
  end

  defp capture_heading_section(doc, heading, headings) do
    with {heading_idx, _} <- :binary.match(doc, heading),
         section_start <- heading_idx + byte_size(heading),
         true <- section_start + 2 <= byte_size(doc),
         "\n\n" <- binary_part(doc, section_start, 2) do
      content = binary_part(doc, section_start + 2, byte_size(doc) - section_start - 2)

      headings
      |> Enum.filter(&(&1 != heading))
      |> Enum.map(&("\n" <> &1))
      |> Enum.map(fn marker -> :binary.match(content, marker) end)
      |> Enum.reject(&(&1 == :nomatch))
      |> Enum.map(fn {idx, _} -> idx end)
      |> case do
        [] -> content
        indexes -> binary_part(content, 0, Enum.min(indexes))
      end
    else
      :nomatch -> nil
      false -> ""
      _ -> nil
    end
  end
end
