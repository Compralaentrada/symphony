defmodule Mix.Tasks.Title.Check do
  use Mix.Task

  @shortdoc "Validate an issue, PR, or commit title"

  @moduledoc """
  Validates the repository's Conventional Commit title format.

  Usage:

      mix title.check --title "feat(projects): usar estados canónicos"
  """

  @max_length 72
  @allowed_types ~w(feat fix docs refactor test ci build chore perf security)
  @title_pattern Regex.compile!("\\A(?:#{Enum.join(@allowed_types, "|")})\\([a-z0-9]+(?:-[a-z0-9]+)*\\)!?: \\S[^\\r\\n]*\\z")

  @impl Mix.Task
  @spec run([String.t()]) :: :ok | no_return()
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args, strict: [title: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      argv != [] ->
        Mix.raise("Unexpected argument(s): #{Enum.join(argv, " ")}")

      is_nil(opts[:title]) ->
        Mix.raise("Missing required option --title")

      true ->
        validate_title(opts[:title])
    end
  end

  defp validate_title(title) do
    errors =
      []
      |> check_format(title)
      |> check_length(title)
      |> check_final_period(title)
      |> check_whitespace(title)

    if errors == [] do
      Mix.shell().info("Title format OK")
      :ok
    else
      Enum.each(errors, fn error -> Mix.shell().error(error) end)
      Mix.raise("Conventional Commit title invalid.")
    end
  end

  defp check_format(errors, title) do
    if Regex.match?(@title_pattern, title) do
      errors
    else
      errors ++
        [
          "Expected `type(scope): description` using types: #{Enum.join(@allowed_types, ", ")}; scope must be lowercase kebab-case."
        ]
    end
  end

  defp check_length(errors, title) do
    if String.length(title) <= @max_length do
      errors
    else
      errors ++ ["Title must be at most #{@max_length} characters."]
    end
  end

  defp check_final_period(errors, title) do
    if String.ends_with?(title, ".") do
      errors ++ ["Title must not end with a period."]
    else
      errors
    end
  end

  defp check_whitespace(errors, title) do
    if String.trim(title) == title do
      errors
    else
      errors ++ ["Title must not start or end with whitespace."]
    end
  end
end
