defmodule SymphonyElixir.Asana.Client do
  @moduledoc """
  Thin Asana REST client for project-scoped task polling.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @default_endpoint "https://app.asana.com/api/1.0"
  @page_size 100
  @task_fields [
    "gid",
    "name",
    "notes",
    "completed",
    "resource_subtype",
    "assignee.gid",
    "tags.name",
    "memberships.project.gid",
    "memberships.section.gid",
    "memberships.section.name",
    "permalink_url",
    "created_at",
    "modified_at"
  ]
  @task_fields_query Enum.join(@task_fields, ",")

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    ["ASANA_PAT" | env_reference_names([provider["api_key"]])]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) when is_list(states) do
    fetch_issues_by_states(states, Config.settings!().tracker, &perform_request/5)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids) when is_list(ids) do
    fetch_issues_by_ids(ids, Config.settings!().tracker, &perform_request/5)
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, query, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(query) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, asana_settings} <- settings(tracker_settings) do
      request_fun.(method, path, query, body, asana_settings)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), map()) :: Issue.t() | nil
  def normalize_issue_for_test(task, tracker_settings)
      when is_map(task) and is_map(tracker_settings) do
    case settings(tracker_settings) do
      {:ok, asana_settings} -> normalize_issue(task, asana_settings)
      _ -> nil
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, tracker_settings, request_fun)
      when is_list(states) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_states(states, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(ids, tracker_settings, request_fun)
      when is_list(ids) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_ids(ids, tracker_settings, request_fun)
  end

  defp fetch_issues_by_states([], _tracker_settings, _request_fun), do: {:ok, []}

  defp fetch_issues_by_states(states, tracker_settings, request_fun) do
    with {:ok, asana_settings} <- settings(tracker_settings) do
      fetch_task_pages(states, asana_settings, nil, request_fun, [])
    end
  end

  defp fetch_task_pages(states, settings, offset, request_fun, pages) do
    query =
      %{
        "limit" => @page_size,
        "opt_fields" => @task_fields_query
      }
      |> maybe_put("offset", offset)

    with {:ok, payload} <-
           request_with_settings(
             "GET",
             "/projects/#{encoded(settings.project_gid)}/tasks",
             query,
             nil,
             settings,
             request_fun,
             false
           ),
         {:ok, raw_tasks, next_offset} <- task_page(payload) do
      issues = normalize_candidate_page(raw_tasks, settings, states)
      updated_pages = [issues | pages]

      case next_offset do
        :done -> {:ok, updated_pages |> Enum.reverse() |> List.flatten()}
        next -> fetch_task_pages(states, settings, next, request_fun, updated_pages)
      end
    end
  end

  defp fetch_issues_by_ids([], _tracker_settings, _request_fun), do: {:ok, []}

  defp fetch_issues_by_ids(ids, tracker_settings, request_fun) do
    with {:ok, asana_settings} <- settings(tracker_settings) do
      ids
      |> Enum.uniq()
      |> fetch_task_ids(asana_settings, request_fun, [])
    end
  end

  defp fetch_task_ids([], _settings, _request_fun, issues), do: {:ok, Enum.reverse(issues)}

  defp fetch_task_ids([id | rest], settings, request_fun, issues) do
    with {:ok, payload} <-
           request_with_settings(
             "GET",
             "/tasks/#{encoded(id)}",
             %{"opt_fields" => @task_fields_query},
             nil,
             settings,
             request_fun,
             true
           ) do
      continue_task_id_fetch(payload, rest, settings, request_fun, issues)
    end
  end

  defp continue_task_id_fetch(:not_found, rest, settings, request_fun, issues) do
    fetch_task_ids(rest, settings, request_fun, issues)
  end

  defp continue_task_id_fetch(%{"data" => raw_task}, rest, settings, request_fun, issues)
       when is_map(raw_task) do
    if task_outside_project?(raw_task, settings.project_gid) do
      fetch_task_ids(rest, settings, request_fun, issues)
    else
      case normalize_issue(raw_task, settings) do
        %Issue{} = issue -> fetch_task_ids(rest, settings, request_fun, [issue | issues])
        nil -> {:error, :asana_unknown_payload}
      end
    end
  end

  defp continue_task_id_fetch(_payload, _rest, _settings, _request_fun, _issues) do
    {:error, :asana_unknown_payload}
  end

  defp task_page(%{"data" => tasks, "next_page" => nil}) when is_list(tasks) do
    {:ok, tasks, :done}
  end

  defp task_page(%{"data" => tasks, "next_page" => %{"offset" => offset}})
       when is_list(tasks) and is_binary(offset) and offset != "" do
    {:ok, tasks, offset}
  end

  defp task_page(%{"data" => tasks, "next_page" => next_page})
       when is_list(tasks) and is_map(next_page) do
    {:error, :asana_missing_next_page_offset}
  end

  defp task_page(_payload), do: {:error, :asana_unknown_payload}

  defp normalize_candidate_page(raw_tasks, settings, states) do
    requested_states = states |> Enum.map(&normalize_state/1) |> MapSet.new()
    issues = Enum.map(raw_tasks, &normalize_issue(&1, settings))
    malformed_count = Enum.count(issues, &is_nil/1)

    if malformed_count > 0 do
      Logger.warning("Dropping malformed Asana task records count=#{malformed_count}")
    end

    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&MapSet.member?(requested_states, normalize_state(&1.state)))
  end

  defp normalize_issue(%{"gid" => gid, "name" => name} = task, settings)
       when is_binary(gid) and is_binary(name) do
    membership = project_membership(task, settings.project_gid)
    state = get_in(membership, ["section", "name"])

    if present_string?(gid) and present_string?(name) and present_string?(state) do
      %Issue{
        id: gid,
        native_ref: native_ref(gid, settings.project_gid, membership),
        identifier: "ASANA-#{gid}",
        title: name,
        description: blank_to_nil(task["notes"]),
        priority: nil,
        state: state,
        branch_name: nil,
        url: task["permalink_url"],
        assignee_id: get_in(task, ["assignee", "gid"]),
        labels: extract_labels(task["tags"]),
        blocked_by: [],
        dispatchable: task["completed"] == false and task["resource_subtype"] != "section",
        created_at: parse_datetime(task["created_at"]),
        updated_at: parse_datetime(task["modified_at"])
      }
    end
  end

  defp normalize_issue(_task, _settings), do: nil

  defp project_membership(%{"memberships" => memberships}, project_gid) when is_list(memberships) do
    Enum.find(memberships, &(get_in(&1, ["project", "gid"]) == project_gid))
  end

  defp project_membership(_task, _project_gid), do: nil

  defp task_outside_project?(%{"gid" => gid, "name" => name, "memberships" => memberships}, project_gid)
       when is_binary(gid) and is_binary(name) and is_list(memberships) do
    present_string?(gid) and present_string?(name) and is_nil(project_membership(%{"memberships" => memberships}, project_gid))
  end

  defp task_outside_project?(_task, _project_gid), do: false

  defp native_ref(task_gid, project_gid, membership) do
    %{
      "task_gid" => task_gid,
      "project_gid" => project_gid,
      "section_gid" => get_in(membership, ["section", "gid"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp extract_labels(tags) when is_list(tags) do
    tags
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_tags), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_value), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp request_with_settings(method, path, query, body, settings, request_fun, allow_not_found) do
    case request_fun.(method, path, query, body, settings) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %{status: 404}} when allow_not_found ->
        {:ok, :not_found}

      {:ok, %{status: status}} when is_integer(status) ->
        Logger.error("Asana API request failed status=#{status} method=#{method} path=#{path}")
        {:error, {:asana_api_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :asana_unknown_payload}
    end
  end

  defp perform_request(method, path, query, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      request_opts = [
        method: request_method,
        url: settings.endpoint <> path,
        headers: asana_headers(settings.api_key),
        params: query,
        connect_options: [timeout: 30_000]
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(request_opts) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, {:asana_api_request, reason}}
      end
    end
  end

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    endpoint = provider["endpoint"] || @default_endpoint
    api_key = resolve_setting(provider["api_key"], System.get_env("ASANA_PAT"))
    project_gid = resolve_setting(provider["project_gid"], nil)

    cond do
      not valid_endpoint?(endpoint) ->
        {:error, :invalid_asana_endpoint}

      not present_string?(api_key) ->
        {:error, :missing_asana_api_key}

      not present_string?(project_gid) ->
        {:error, :missing_asana_project_gid}

      true ->
        {:ok,
         %{
           endpoint: String.trim_trailing(endpoint, "/"),
           api_key: api_key,
           project_gid: project_gid
         }}
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || fallback)
    else
      nil
    end
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name when is_binary(env_name) -> if valid_env_name?(env_name), do: [env_name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_endpoint?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_endpoint?(_value), do: false

  defp asana_headers(api_key) do
    [
      {"Accept", "application/json"},
      {"Authorization", "Bearer #{api_key}"}
    ]
  end

  defp encoded(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_asana_method}

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
