defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira REST client for tracker polling and claim lease comments.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}
  alias SymphonyElixir.Tracker.ClaimLease

  @issue_page_size 50
  @comment_page_size 100
  @issue_fields "summary,description,priority,status,labels,assignee,created,updated"
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_jira_api_token}

      is_nil(tracker.project_slug) ->
        {:error, :missing_jira_project_key}

      true ->
        tracker.project_slug
        |> project_states_jql(tracker.active_states)
        |> fetch_issues_by_jql()
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_jira_api_token}

        is_nil(tracker.project_slug) ->
          {:error, :missing_jira_project_key}

        true ->
          tracker.project_slug
          |> project_states_jql(states)
          |> fetch_issues_by_jql()
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids =
      issue_ids
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case ids do
      [] -> {:ok, []}
      ids -> ids |> issue_ids_jql() |> fetch_issues_by_jql()
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case create_comment_document(issue_id, plain_text_doc(body)) do
      {:ok, _comment_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec upsert_claim_lease(String.t(), map()) :: {:ok, ClaimLease.t()} | {:error, term()}
  def upsert_claim_lease(issue_id, lease_attrs) when is_binary(issue_id) and is_map(lease_attrs) do
    with {:ok, comments} <- fetch_issue_comments(issue_id) do
      upsert_claim_lease_comment(issue_id, lease_attrs, comments)
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, transitions} <- fetch_transitions(issue_id),
         {:ok, transition_id} <- resolve_transition_id(transitions, state_name),
         {:ok, _body} <-
           request_json(:post, "/issue/#{url_path_token(issue_id)}/transitions", json: %{"transition" => %{"id" => transition_id}}) do
      :ok
    end
  end

  @doc false
  @spec adf_to_text_for_test(term()) :: String.t()
  def adf_to_text_for_test(value), do: adf_to_text(value)

  defp fetch_issues_by_jql(jql) when is_binary(jql) do
    do_fetch_issues_by_jql(jql, 0, [])
  end

  defp do_fetch_issues_by_jql(jql, start_at, acc_issues) do
    with {:ok, body} <-
           request_json(:get, "/search",
             params: %{
               jql: jql,
               startAt: start_at,
               maxResults: @issue_page_size,
               fields: @issue_fields
             }
           ),
         {:ok, issues, page_info} <- decode_issue_page(body),
         {:ok, normalized_issues} <- normalize_issues(issues) do
      updated_acc = Enum.reverse(normalized_issues, acc_issues)

      if page_info.next_start_at do
        do_fetch_issues_by_jql(jql, page_info.next_start_at, updated_acc)
      else
        {:ok, Enum.reverse(updated_acc)}
      end
    end
  end

  defp decode_issue_page(%{"issues" => issues} = body) when is_list(issues) do
    start_at = integer_value(body["startAt"], 0)
    max_results = integer_value(body["maxResults"], length(issues))
    total = integer_value(body["total"], start_at + length(issues))
    next_start_at = next_start_at(start_at, max_results, length(issues), total)

    {:ok, issues, %{next_start_at: next_start_at}}
  end

  defp decode_issue_page(%{"errorMessages" => errors}), do: {:error, {:jira_errors, errors}}
  defp decode_issue_page(_body), do: {:error, :jira_unknown_payload}

  defp next_start_at(start_at, max_results, issue_count, total) do
    candidate = start_at + max(max_results, issue_count)

    cond do
      issue_count == 0 -> nil
      candidate < total -> candidate
      true -> nil
    end
  end

  defp normalize_issues(issues) when is_list(issues) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      issue_id_or_key = issue["key"] || issue["id"]

      with {:ok, comments} <- fetch_issue_comments(issue_id_or_key),
           %Issue{} = normalized_issue <- normalize_issue(issue, comments) do
        {:cont, {:ok, [normalized_issue | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, normalized_issues} -> {:ok, Enum.reverse(normalized_issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_issue(%{"fields" => fields} = issue, comments) when is_map(fields) do
    %Issue{
      id: normalize_string(issue["id"]),
      identifier: normalize_string(issue["key"]),
      title: normalize_string(fields["summary"]),
      description: adf_to_text(fields["description"]),
      priority: parse_priority(fields["priority"]),
      state: get_in(fields, ["status", "name"]),
      branch_name: nil,
      url: browse_url(issue["key"]),
      assignee_id: get_in(fields, ["assignee", "accountId"]),
      labels: extract_labels(fields),
      assigned_to_worker: true,
      claim_lease: ClaimLease.find(comments),
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp normalize_issue(_issue, _comments), do: nil

  defp fetch_issue_comments(issue_id_or_key) when is_binary(issue_id_or_key) do
    do_fetch_issue_comments(issue_id_or_key, 0, [])
  end

  defp fetch_issue_comments(_issue_id_or_key), do: {:ok, []}

  defp do_fetch_issue_comments(issue_id_or_key, start_at, acc_comments) do
    with {:ok, body} <-
           request_json(:get, "/issue/#{url_path_token(issue_id_or_key)}/comment", params: %{startAt: start_at, maxResults: @comment_page_size}),
         {:ok, comments, page_info} <- decode_comment_page(body) do
      updated_acc = Enum.reverse(comments, acc_comments)

      if page_info.next_start_at do
        do_fetch_issue_comments(issue_id_or_key, page_info.next_start_at, updated_acc)
      else
        {:ok, Enum.reverse(updated_acc)}
      end
    end
  end

  defp decode_comment_page(%{"comments" => comments} = body) when is_list(comments) do
    normalized_comments =
      comments
      |> Enum.map(&normalize_comment/1)
      |> Enum.reject(&is_nil/1)

    start_at = integer_value(body["startAt"], 0)
    max_results = integer_value(body["maxResults"], length(comments))
    total = integer_value(body["total"], start_at + length(comments))
    next_start_at = next_start_at(start_at, max_results, length(comments), total)

    {:ok, normalized_comments, %{next_start_at: next_start_at}}
  end

  defp decode_comment_page(%{"errorMessages" => errors}), do: {:error, {:jira_errors, errors}}
  defp decode_comment_page(_body), do: {:error, :jira_unknown_payload}

  defp normalize_comment(%{"id" => id, "body" => body}) do
    %{id: normalize_string(id), body: adf_to_text(body)}
  end

  defp normalize_comment(_comment), do: nil

  defp fetch_transitions(issue_id) do
    case request_json(:get, "/issue/#{url_path_token(issue_id)}/transitions") do
      {:ok, %{"transitions" => transitions}} when is_list(transitions) -> {:ok, transitions}
      {:ok, _body} -> {:error, :jira_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_claim_lease_comment(issue_id, lease_attrs, comments) do
    lease_body = ClaimLease.render(Map.put(lease_attrs, :issue_id, issue_id))

    case ClaimLease.find(comments) do
      %ClaimLease{comment_id: comment_id} when is_binary(comment_id) ->
        update_claim_lease_comment(issue_id, comment_id, lease_attrs, lease_body)

      _missing ->
        create_claim_lease_comment(issue_id, lease_attrs, lease_body)
    end
  end

  defp update_claim_lease_comment(issue_id, comment_id, lease_attrs, lease_body) do
    with :ok <- update_comment_document(issue_id, comment_id, marker_doc(lease_body)) do
      {:ok, claim_lease_with_comment_id(lease_attrs, issue_id, comment_id)}
    end
  end

  defp create_claim_lease_comment(issue_id, lease_attrs, lease_body) do
    with {:ok, comment_id} <- create_comment_document(issue_id, marker_doc(lease_body)) do
      {:ok, claim_lease_with_comment_id(lease_attrs, issue_id, comment_id)}
    end
  end

  defp claim_lease_with_comment_id(lease_attrs, issue_id, comment_id) do
    lease_attrs
    |> Map.put(:issue_id, issue_id)
    |> Map.put(:comment_id, comment_id)
    |> ClaimLease.new()
  end

  defp resolve_transition_id(transitions, state_name) when is_list(transitions) and is_binary(state_name) do
    normalized_state = normalize_state_name(state_name)

    transitions
    |> Enum.find(fn transition ->
      transition_name = normalize_state_name(transition["name"])
      target_name = normalize_state_name(get_in(transition, ["to", "name"]))

      transition_name == normalized_state or target_name == normalized_state
    end)
    |> case do
      %{"id" => id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :jira_transition_not_found}
    end
  end

  defp create_comment_document(issue_id, adf_body) do
    with {:ok, body} <- request_json(:post, "/issue/#{url_path_token(issue_id)}/comment", json: %{"body" => adf_body}) do
      case normalize_string(body["id"]) do
        nil -> {:error, :jira_comment_create_failed}
        comment_id -> {:ok, comment_id}
      end
    end
  end

  defp update_comment_document(issue_id, comment_id, adf_body) do
    with {:ok, _body} <-
           request_json(:put, "/issue/#{url_path_token(issue_id)}/comment/#{url_path_token(comment_id)}", json: %{"body" => adf_body}) do
      :ok
    end
  end

  defp request_json(method, path, opts \\ []) when is_atom(method) and is_binary(path) and is_list(opts) do
    tracker = Config.settings!().tracker

    with {:ok, headers} <- jira_headers(tracker),
         {:ok, %{status: status, body: body}} <- request_fun().(method, path, Keyword.put(opts, :headers, headers), tracker) do
      if status in 200..299 do
        {:ok, body || %{}}
      else
        Logger.error("Jira REST request failed method=#{method} path=#{path} status=#{status} body=#{summarize_error_body(body)}")
        {:error, {:jira_api_status, status}}
      end
    else
      {:error, reason} ->
        Logger.error("Jira REST request failed method=#{method} path=#{path}: #{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  defp request_fun do
    Application.get_env(:symphony_elixir, :jira_request_fun, &default_request/4)
  end

  defp default_request(method, path, opts, tracker) do
    Req.request(
      method: method,
      url: jira_api_url(tracker.endpoint, path),
      headers: Keyword.fetch!(opts, :headers),
      params: Keyword.get(opts, :params),
      json: Keyword.get(opts, :json),
      connect_options: [timeout: 30_000]
    )
  end

  defp jira_headers(tracker) do
    case normalize_string(tracker.api_key) do
      nil ->
        {:error, :missing_jira_api_token}

      token ->
        {:ok,
         [
           {"Authorization", authorization_header(token)},
           {"Accept", "application/json"},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp authorization_header("Basic " <> _rest = token), do: token
  defp authorization_header("Bearer " <> _rest = token), do: token
  defp authorization_header(token), do: "Bearer #{token}"

  defp jira_api_url(endpoint, path) do
    endpoint
    |> normalize_endpoint()
    |> Kernel.<>(path)
  end

  defp normalize_endpoint(endpoint) when is_binary(endpoint) do
    endpoint = String.trim_trailing(endpoint, "/")

    if String.ends_with?(endpoint, "/rest/api/3") do
      endpoint
    else
      endpoint <> "/rest/api/3"
    end
  end

  defp normalize_endpoint(_endpoint), do: "/rest/api/3"

  defp project_states_jql(project_key, states) do
    "project = \"#{escape_jql(project_key)}\" AND status in (#{quoted_jql_values(states)}) ORDER BY priority ASC, created ASC"
  end

  defp issue_ids_jql(ids) do
    if Enum.all?(ids, &String.match?(&1, ~r/^\d+$/)) do
      "id in (#{Enum.join(ids, ", ")})"
    else
      "issuekey in (#{quoted_jql_values(ids)})"
    end
  end

  defp quoted_jql_values(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&escape_jql/1)
    |> Enum.map_join(", ", &~s("#{&1}"))
  end

  defp escape_jql(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp url_path_token(value) do
    value
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  defp marker_doc(body) when is_binary(body) do
    %{
      "type" => "doc",
      "version" => 1,
      "content" => [
        %{
          "type" => "codeBlock",
          "attrs" => %{"language" => "json"},
          "content" => [%{"type" => "text", "text" => body}]
        }
      ]
    }
  end

  defp plain_text_doc(body) when is_binary(body) do
    content =
      body
      |> String.split("\n", trim: false)
      |> Enum.map(fn
        "" -> %{"type" => "paragraph"}
        line -> %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => line}]}
      end)

    %{"type" => "doc", "version" => 1, "content" => content}
  end

  defp adf_to_text(value) when is_binary(value), do: value

  defp adf_to_text(%{"text" => text}) when is_binary(text), do: text
  defp adf_to_text(%{"type" => "hardBreak"}), do: "\n"

  defp adf_to_text(%{"type" => type, "content" => content}) when is_list(content) do
    content
    |> Enum.map_join("", &adf_to_text/1)
    |> maybe_append_block_break(type)
  end

  defp adf_to_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "", &adf_to_text/1)
  end

  defp adf_to_text(value) when is_list(value), do: Enum.map_join(value, "", &adf_to_text/1)
  defp adf_to_text(_value), do: ""

  defp maybe_append_block_break(text, type) when type in ["paragraph", "codeBlock", "listItem", "heading"] do
    text <> "\n"
  end

  defp maybe_append_block_break(text, _type), do: text

  defp browse_url(key) when is_binary(key) do
    endpoint = Config.settings!().tracker.endpoint

    case URI.parse(to_string(endpoint)) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}/browse/#{key}"

      _ ->
        nil
    end
  end

  defp browse_url(_key), do: nil

  defp parse_priority(%{"name" => name}) when is_binary(name) do
    case normalize_state_name(name) do
      "highest" -> 1
      "high" -> 2
      "medium" -> 3
      "low" -> 4
      "lowest" -> 5
      _ -> nil
    end
  end

  defp parse_priority(%{"id" => id}), do: parse_integer(id)
  defp parse_priority(_priority), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_fields), do: []

  defp integer_value(value, default) do
    case parse_integer(value) do
      nil -> default
      integer -> integer
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string(_value), do: nil

  defp normalize_state_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state_name(_value), do: ""

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
