defmodule Mix.Tasks.PrBody.Check do
  use Mix.Task

  alias SymphonyElixir.PRBody

  @shortdoc "Validate PR body format against the repository PR template"

  @moduledoc """
  Validates a PR description markdown file against the structure and expectations
  implied by the repository pull request template.

  Usage:

      mix pr_body.check --file /path/to/pr_body.md
  """

  @template_paths [
    ".github/pull_request_template.md",
    "../.github/pull_request_template.md"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [file: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        file_path = required_opt(opts, :file)

        with {:ok, template_path, template} <- read_template(),
             {:ok, body} <- read_file(file_path),
             :ok <- lint_and_print(template_path, template, body) do
          Mix.shell().info("PR body format OK")
        else
          {:error, message} -> Mix.raise(message)
        end
    end
  end

  defp read_template do
    case Enum.find_value(@template_paths, &read_template_candidate/1) do
      {:ok, _path, _template} = result ->
        result

      nil ->
        joined_paths = Enum.join(@template_paths, ", ")
        {:error, "Unable to read PR template from any of: #{joined_paths}"}
    end
  end

  defp read_template_candidate(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, path, content}
      {:error, _reason} -> nil
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Unable to read #{path}: #{inspect(reason)}"}
    end
  end

  defp lint_and_print(template_path, template, body) do
    if Regex.match?(~r/^\#{4,6}\s+.+$/m, template) do
      report_lint_errors(template_path, PRBody.lint(template, body))
    else
      {:error, "No markdown headings found in #{template_path}"}
    end
  end

  defp report_lint_errors(_template_path, []), do: :ok

  defp report_lint_errors(template_path, errors) do
    Enum.each(errors, fn err -> Mix.shell().error("ERROR: #{err}") end)
    {:error, "PR body format invalid. Read `#{template_path}` and follow it precisely."}
  end
end
