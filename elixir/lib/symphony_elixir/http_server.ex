defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Lightweight HTTP server for the optional observability endpoints.
  """

  use GenServer

  alias SymphonyElixir.{Config, Orchestrator}

  @accept_timeout_ms 100
  @recv_timeout_ms 1_000
  @max_header_bytes 8_192
  @max_body_bytes 1_048_576

  defmodule State do
    @moduledoc false

    defstruct [:listen_socket, :port, :orchestrator, :snapshot_timeout_ms]
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, Keyword.put(opts, :port, port), name: name)

      _ ->
        :ignore
    end
  end

  @spec bound_port(GenServer.name()) :: non_neg_integer() | nil
  def bound_port(server \\ __MODULE__) do
    case Process.whereis(server) do
      pid when is_pid(pid) ->
        GenServer.call(server, :bound_port)

      _ ->
        nil
    end
  end

  @impl true
  def init(opts) do
    host = Keyword.get(opts, :host, Config.server_host())
    port = Keyword.fetch!(opts, :port)
    orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
    snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

    with {:ok, ip} <- parse_host(host),
         {:ok, listen_socket} <-
           :gen_tcp.listen(port, [:binary, {:ip, ip}, {:packet, :raw}, {:active, false}, {:reuseaddr, true}]),
         {:ok, actual_port} <- :inet.port(listen_socket) do
      send(self(), :accept)

      {:ok,
       %State{
         listen_socket: listen_socket,
         port: actual_port,
         orchestrator: orchestrator,
         snapshot_timeout_ms: snapshot_timeout_ms
       }}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:bound_port, _from, %State{port: port} = state) do
    {:reply, port, state}
  end

  @impl true
  def handle_info(
        :accept,
        %State{
          listen_socket: listen_socket,
          orchestrator: orchestrator,
          snapshot_timeout_ms: snapshot_timeout_ms
        } = state
      ) do
    case :gen_tcp.accept(listen_socket, @accept_timeout_ms) do
      {:ok, socket} ->
        {:ok, _pid} =
          Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
            serve_connection(socket, orchestrator, snapshot_timeout_ms)
          end)

        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  @impl true
  def terminate(_reason, %State{listen_socket: listen_socket}) when is_port(listen_socket) do
    :gen_tcp.close(listen_socket)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @spec parse_raw_request_for_test(String.t()) ::
          {:ok, String.t(), map(), String.t()} | {:error, :bad_request}
  def parse_raw_request_for_test(data) when is_binary(data), do: parse_raw_request(data)

  @spec parse_host_for_test(String.t() | :inet.ip_address()) :: {:ok, :inet.ip_address()} | {:error, term()}
  def parse_host_for_test(host), do: parse_host(host)

  defp serve_connection(socket, orchestrator, snapshot_timeout_ms) do
    case read_request(socket) do
      {:ok, request} ->
        :ok = :gen_tcp.send(socket, route(request, orchestrator, snapshot_timeout_ms))

      {:error, reason} ->
        case request_error_response(reason) do
          nil -> :ok
          response -> :ok = :gen_tcp.send(socket, response)
        end
    end
  after
    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, data} <- recv_until_headers(socket, ""),
         {:ok, request_line, headers, remainder} <- parse_raw_request(data),
         {:ok, method, path} <- parse_request_line(request_line),
         {:ok, body} <- read_body(socket, headers, remainder) do
      {:ok, %{method: method, path: path, headers: headers, body: body}}
    end
  end

  defp recv_until_headers(socket, acc) do
    cond do
      byte_size(acc) > @max_header_bytes ->
        {:error, :headers_too_large}

      String.contains?(acc, "\r\n\r\n") ->
        {:ok, acc}

      true ->
        case :gen_tcp.recv(socket, 0, @recv_timeout_ms) do
          {:ok, chunk} -> recv_until_headers(socket, acc <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_raw_request(data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [head, remainder] ->
        case String.split(head, "\r\n", trim: true) do
          [request_line | header_lines] ->
            {:ok, request_line, parse_headers(header_lines), remainder}

          _ ->
            {:error, :bad_request}
        end

      _ ->
        {:error, :bad_request}
    end
  end

  defp parse_headers(header_lines) do
    Enum.reduce(header_lines, %{}, fn line, headers ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          Map.put(headers, String.downcase(String.trim(name)), String.trim(value))

        _ ->
          headers
      end
    end)
  end

  defp parse_request_line(line) do
    case String.split(line, " ", parts: 3) do
      [method, path, _version] -> {:ok, method, path}
      _ -> {:error, :bad_request}
    end
  end

  defp read_body(socket, headers, remainder) do
    content_length =
      headers
      |> Map.get("content-length", "0")
      |> Integer.parse()
      |> case do
        {length, _} when length >= 0 -> length
        _ -> 0
      end

    cond do
      content_length > @max_body_bytes ->
        {:error, :body_too_large}

      byte_size(remainder) >= content_length ->
        {:ok, binary_part(remainder, 0, content_length)}

      true ->
        case :gen_tcp.recv(socket, content_length - byte_size(remainder), @recv_timeout_ms) do
          {:ok, tail} -> {:ok, remainder <> tail}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp route(%{method: "GET", path: "/"} = request, orchestrator, snapshot_timeout_ms),
    do: html_response(200, render_dashboard(request, orchestrator, snapshot_timeout_ms))

  defp route(%{method: "GET", path: "/api/v1/state"}, orchestrator, snapshot_timeout_ms),
    do: json_response(200, state_payload(orchestrator, snapshot_timeout_ms))

  defp route(%{method: "POST", path: "/api/v1/refresh"}, orchestrator, _snapshot_timeout_ms) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        error_response(503, "orchestrator_unavailable", "Orchestrator is unavailable")

      payload ->
        json_response(202, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1))
    end
  end

  defp route(%{path: "/api/v1/state"}, _orchestrator, _snapshot_timeout_ms),
    do: error_response(405, "method_not_allowed", "Method not allowed")

  defp route(%{path: "/api/v1/refresh"}, _orchestrator, _snapshot_timeout_ms),
    do: error_response(405, "method_not_allowed", "Method not allowed")

  defp route(%{method: "GET", path: "/api/v1/" <> issue_identifier}, orchestrator, snapshot_timeout_ms) do
    case issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) do
      {:ok, payload} -> json_response(200, payload)
      {:error, :issue_not_found} -> error_response(404, "issue_not_found", "Issue not found")
    end
  end

  defp route(%{path: "/"}, _orchestrator, _snapshot_timeout_ms),
    do: error_response(405, "method_not_allowed", "Method not allowed")

  defp route(%{path: "/api/v1/" <> _issue_identifier}, _orchestrator, _snapshot_timeout_ms),
    do: error_response(405, "method_not_allowed", "Method not allowed")

  defp route(_request, _orchestrator, _snapshot_timeout_ms),
    do: error_response(404, "not_found", "Route not found")

  defp state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  defp issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: Path.join(Config.workspace_root(), issue_identifier)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error
    }
  end

  defp running_issue_payload(running) do
    %{
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error
    }
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp render_dashboard(_request, orchestrator, snapshot_timeout_ms) do
    payload = state_payload(orchestrator, snapshot_timeout_ms)
    title = "Symphony Dashboard"
    body = Jason.encode!(payload, pretty: true)
    escaped_body = escape_html(body)

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>#{title}</title>
        <style>
          body { font-family: Menlo, Monaco, monospace; margin: 24px; background: #f4efe6; color: #1f1d1a; }
          h1 { margin: 0 0 16px; }
          pre { padding: 16px; border-radius: 12px; background: #fffdf8; border: 1px solid #d8cfbf; overflow: auto; }
        </style>
      </head>
      <body>
        <h1>#{title}</h1>
        <pre>#{escaped_body}</pre>
      </body>
    </html>
    """
  end

  defp escape_html(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp parse_host({_, _, _, _} = ip), do: {:ok, ip}
  defp parse_host({_, _, _, _, _, _, _, _} = ip), do: {:ok, ip}

  defp parse_host(host) when is_binary(host) do
    charhost = String.to_charlist(host)

    case :inet.parse_address(charhost) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _reason} ->
        case :inet.getaddr(charhost, :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _reason} -> :inet.getaddr(charhost, :inet6)
        end
    end
  end

  defp json_response(status, payload) do
    body = Jason.encode!(payload)
    build_response(status, "application/json; charset=utf-8", body)
  end

  defp html_response(status, body) do
    build_response(status, "text/html; charset=utf-8", body)
  end

  defp error_response(status, code, message) do
    json_response(status, %{error: %{code: code, message: message}})
  end

  defp build_response(status, content_type, body) do
    [
      "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n",
      "content-type: #{content_type}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ]
    |> IO.iodata_to_binary()
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(202), do: "Accepted"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(413), do: "Payload Too Large"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(405), do: "Method Not Allowed"
  defp reason_phrase(503), do: "Service Unavailable"

  defp request_error_response(:closed), do: nil

  defp request_error_response(:headers_too_large),
    do: error_response(413, "headers_too_large", "Request headers exceed the maximum size")

  defp request_error_response(:body_too_large),
    do: error_response(413, "body_too_large", "Request body exceeds the maximum size")

  defp request_error_response(_reason),
    do: error_response(400, "bad_request", "Malformed HTTP request")

  defp summarize_message(%{message: message}) when is_binary(message), do: message
  defp summarize_message(message) when is_binary(message), do: message
  defp summarize_message(_message), do: nil

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
