defmodule SymphonyElixir.GitHub.AgentTool do
  @moduledoc """
  Provider-native GitHub REST tool exposed to Codex app-server turns.
  """

  alias SymphonyElixir.GitHub.Client

  @github_api_tool "github_api"
  @allowed_methods ["GET"]
  @github_workflow_tool "github_workflow"
  @workflow_operations %{
    "build" => ["claim", "read_workpad", "workpad", "handoff", "create_follow_up_issue"],
    "qa" => ["claim", "read_workpad", "workpad", "handoff", "create_follow_up_issue"],
    "review" => ["read_workpad", "workpad", "handoff", "create_follow_up_issue"],
    "diagnostic" => ["read_workpad", "workpad", "handoff"],
    "finalize" => ["read_workpad", "workpad", "handoff"],
    "individual" => ["claim", "workpad", "handoff", "create_follow_up_issue", "release_claim"]
  }
  @github_api_description """
  Read GitHub data for the repository attached to this task using Symphony's configured auth.
  """
  @github_workflow_description "Read this task's saved workpad and phase reports, or perform a GitHub write authorized for this task and phase."
  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => @allowed_methods,
        "description" => "Read-only GitHub REST method."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitHub REST path such as /repos/owner/repo/issues/1/comments."
      },
      "params" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "description" => "Optional JSON request body."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @github_api_tool -> execute_github_api(arguments, opts)
      @github_workflow_tool -> execute_github_workflow(arguments, opts)
      other -> unsupported_tool_response(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @github_api_tool,
        "description" => @github_api_description,
        "inputSchema" => @github_api_input_schema
      }
    ]
  end

  @spec tool_specs(map()) :: [map()]
  def tool_specs(context) when is_map(context) do
    tool_specs() ++ if(valid_context?(context), do: [workflow_tool_spec(allowed_operations(context))], else: [])
  end

  defp execute_github_api(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings, :agent_context])
    context = Keyword.get(opts, :agent_context)

    with {:ok, method, path, params, body} <- normalize_arguments(arguments),
         :ok <- authorize_read(context, method, path),
         {:ok, %{status: status, body: response_body}} <-
           github_client.(method, path, params, body, client_opts),
         true <- is_integer(status) do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:github_unknown_payload))
    end
  end

  defp execute_github_workflow(arguments, opts) when is_map(arguments) do
    context = Keyword.get(opts, :agent_context)
    operation = Map.get(arguments, "operation")

    with true <- valid_context?(context),
         true <- operation in allowed_operations(context),
         {:ok, evidence} <- workflow_client(opts).(context, operation, arguments) do
      workflow_response(evidence)
    else
      false -> failure_response(%{"error" => %{"message" => "This GitHub operation is not authorized for the active task phase."}})
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(%{"error" => %{"message" => "Invalid GitHub workflow tool arguments."}})
    end
  end

  defp execute_github_workflow(_arguments, _opts),
    do: failure_response(%{"error" => %{"message" => "Invalid GitHub workflow tool arguments."}})

  defp workflow_client(opts) do
    Keyword.get(opts, :workflow_client, fn context, operation, arguments ->
      case Map.get(Keyword.get(opts, :tracker_settings, %{}), :kind) do
        "github_projects" ->
          SymphonyElixir.GitHub.Projects.Client.agent_operation(context.issue, context, operation, arguments, opts)

        "github" ->
          SymphonyElixir.GitHub.Client.agent_operation(context.issue, context, operation, arguments, opts)

        _ ->
          {:error, :github_tracker_required}
      end
    end)
  end

  defp authorize_read(context, "GET", path) do
    with true <- valid_context?(context),
         {:ok, repository} <- task_repository(context),
         true <- path == "/user" or String.starts_with?(path, "/repos/#{repository}/"),
         false <- String.contains?(path, ["..", "%", "?", "#"]) do
      :ok
    else
      _ -> {:error, :github_read_outside_task_repository}
    end
  end

  defp valid_context?(%{issue: %SymphonyElixir.Tracker.Issue{}, lane: lane}),
    do: lane in [:build, :qa, :review, :diagnostic, :individual, :finalize, "build", "qa", "review", "diagnostic", "individual", "finalize"]

  defp valid_context?(_context), do: false

  defp allowed_operations(%{lane: lane} = context) do
    lane = to_string(lane)
    operations = Map.get(@workflow_operations, lane, [])
    operations = if Map.get(context, :tracker_kind) == "github_projects", do: operations, else: List.delete(operations, "read_workpad")
    operations = if lane == "review" and Map.get(context, :merge_policy) == "auto", do: operations ++ ["request_merge"], else: operations
    if lane == "individual" and Map.get(context, :tracker_kind) != "github", do: List.delete(operations, "release_claim"), else: operations
  end

  defp task_repository(%{issue: %SymphonyElixir.Tracker.Issue{id: id, native_ref: ref}}) do
    case task_repository_name(ref, id) do
      nil -> {:error, :missing_repository}
      repository -> if valid_repository?(repository), do: {:ok, repository}, else: {:error, :invalid_repository}
    end
  end

  defp task_repository_name(ref, id), do: repository_from_ref(ref) || repository_from_id(id)

  defp repository_from_ref(ref) do
    ref = ref || %{}
    Map.get(ref, :repository) || Map.get(ref, "repository") || Map.get(ref, :repo) || Map.get(ref, "repo")
  end

  defp valid_repository?(repository) when is_binary(repository) do
    Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, repository) and not String.contains?(repository, "..")
  end

  defp valid_repository?(_repository), do: false

  defp repository_from_id(id) when is_binary(id) do
    case String.split(id, "#", parts: 2) do
      [repo, number] when repo != number -> repo
      _ -> nil
    end
  end

  defp repository_from_id(_id), do: nil

  defp workflow_tool_spec(operations) do
    %{
      "name" => @github_workflow_tool,
      "description" => @github_workflow_description,
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["operation"],
        "properties" => %{
          "operation" => %{"type" => "string", "enum" => operations},
          "report" => %{
            "type" => ["object", "null"],
            "additionalProperties" => true,
            "properties" => %{
              "pull_request_body" => %{
                "type" => "string",
                "description" =>
                  "For a ready Build or individual handoff, the complete description following .github/pull_request_template.md, with `Fixes #<issue-number>`. Do not include Symphony delivery markers; the host adds them."
              }
            }
          },
          "outcome" => %{"type" => ["string", "null"]},
          "reason" => %{"type" => ["string", "null"]},
          "sha" => %{"type" => ["string", "null"]},
          "finding" => %{"type" => ["object", "null"]},
          "title" => %{"type" => ["string", "null"]},
          "body" => %{
            "type" => ["string", "null"],
            "description" =>
              "For handoff, the complete issue comment with one hidden symphony:report:json HTML comment whose JSON exactly matches report. Keep the PR description in report.pull_request_body."
          }
        }
      }
    }
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, params} <- normalize_params(Map.get(arguments, "params")) do
      {:ok, method, path, params, Map.get(arguments, "body")}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()

    cond do
      normalized in @allowed_methods -> {:ok, normalized}
      normalized in ["POST", "PATCH", "PUT", "DELETE"] -> {:error, :github_write_requires_workflow_tool}
      true -> {:error, :invalid_method}
    end
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    if String.starts_with?(trimmed, "/") and not String.contains?(trimmed, ["://", "\n", "\r", <<0>>]) do
      {:ok, trimmed}
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp normalize_params(nil), do: {:ok, %{}}
  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(_params), do: {:error, :invalid_params}

  defp rest_response(status, body) do
    dynamic_tool_response(status in 200..299, encode_payload(%{"status" => status, "body" => body}))
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp workflow_response(evidence) do
    output = encode_payload(%{"success" => true, "evidence" => evidence})

    %{
      "success" => true,
      "output" => output,
      "evidence" => evidence,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> output
      {:error, _reason} -> inspect(payload)
    end
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`github_api` expects an object with `method` and `path`."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "`github_api.method` must be GET."}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "`github_api.path` must be a relative GitHub REST path."}}
  end

  defp tool_error_payload(:invalid_params) do
    %{"error" => %{"message" => "`github_api.params` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_github_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.provider.token` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:github_read_outside_task_repository) do
    %{"error" => %{"message" => "GitHub reads must stay within the task repository; writes require `github_workflow`."}}
  end

  defp tool_error_payload(:github_write_requires_workflow_tool) do
    %{"error" => %{"message" => "GitHub writes require the lane-authorized `github_workflow` tool."}}
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "GitHub API tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
