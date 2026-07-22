defmodule SymphonyElixir.GitLab.AgentTool do
  @moduledoc """
  Provider-native GitLab REST tool exposed to Codex app-server turns.
  """

  alias SymphonyElixir.GitLab.Client

  @gitlab_api_tool "gitlab_api"
  @allowed_methods ["GET", "POST", "PUT", "DELETE"]
  @gitlab_api_description """
  Execute a GitLab REST API request using Symphony's configured auth.
  """
  @gitlab_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => @allowed_methods,
        "description" => "GitLab REST method."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitLab REST path such as /projects/group%2Frepo/issues/1/notes."
      },
      "query" => %{
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
      @gitlab_api_tool -> execute_gitlab_api(arguments, opts)
      other -> unsupported_tool_response(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @gitlab_api_tool,
        "description" => @gitlab_api_description,
        "inputSchema" => @gitlab_api_input_schema
      }
    ]
  end

  defp execute_gitlab_api(arguments, opts) do
    gitlab_client = Keyword.get(opts, :gitlab_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, method, path, query, body} <- normalize_arguments(arguments),
         {:ok, %{status: status, body: response_body}} <-
           gitlab_client.(method, path, query, body, client_opts),
         true <- is_integer(status) do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:gitlab_unknown_payload))
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, query} <- normalize_query(Map.get(arguments, "query")) do
      {:ok, method, path, query, Map.get(arguments, "body")}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()
    if normalized in @allowed_methods, do: {:ok, normalized}, else: {:error, :invalid_method}
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    if String.starts_with?(trimmed, "/") and
         not String.contains?(trimmed, ["://", "\n", "\r", <<0>>]) do
      {:ok, trimmed}
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp normalize_query(nil), do: {:ok, %{}}
  defp normalize_query(query) when is_map(query), do: {:ok, query}
  defp normalize_query(_query), do: {:error, :invalid_query}

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
    %{"error" => %{"message" => "gitlab_api expects an object with method and path."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "gitlab_api.method must be GET, POST, PUT, or DELETE."}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "gitlab_api.path must be a relative GitLab REST path."}}
  end

  defp tool_error_payload(:invalid_query) do
    %{"error" => %{"message" => "gitlab_api.query must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_gitlab_api_key) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitLab auth. Set tracker.provider.api_key or export GITLAB_PAT."
      }
    }
  end

  defp tool_error_payload({:gitlab_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitLab API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "GitLab REST tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
