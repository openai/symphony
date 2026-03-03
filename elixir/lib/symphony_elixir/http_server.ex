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

  defp route(%{method: "GET", path: "/pomodoro"}, _orchestrator, _snapshot_timeout_ms),
    do: html_response(200, render_pomodoro_app())

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

  defp route(%{path: "/pomodoro"}, _orchestrator, _snapshot_timeout_ms),
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

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>#{title}</title>
        <style>
          body { font-family: Menlo, Monaco, monospace; margin: 24px; background: #f4efe6; color: #1f1d1a; }
          h1 { margin: 0 0 12px; }
          p { margin: 0 0 16px; line-height: 1.5; max-width: 60rem; }
          .nav-links { display: flex; gap: 12px; margin: 0 0 20px; flex-wrap: wrap; }
          .nav-links a { color: #2563eb; text-decoration: none; font-weight: 600; }
          .nav-links a:hover { text-decoration: underline; }
          pre { padding: 16px; border-radius: 12px; background: #fffdf8; border: 1px solid #d8cfbf; overflow: auto; }
        </style>
      </head>
      <body>
        <h1>#{title}</h1>
        <p>
          Optional observability endpoints for the local Symphony runtime.
          For a focused demo experience, open the standalone pomodoro app.
        </p>
        <nav class="nav-links" aria-label="Dashboard links">
          <a href="/pomodoro">Open pomodoro app</a>
          <a href="/api/v1/state">View raw state JSON</a>
        </nav>
        <pre>#{body}</pre>
      </body>
    </html>
    """
  end

  defp render_pomodoro_app do
    ~S"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Pomodoro Timer</title>
        <style>
          :root {
            color-scheme: light;
            --surface: rgba(255, 255, 255, 0.92);
            --surface-strong: rgba(255, 255, 255, 0.97);
            --focus: #ef4444;
            --break: #0f766e;
            --ink: #172033;
            --muted: #52607a;
            --border: rgba(148, 163, 184, 0.25);
            --shadow: 0 24px 60px rgba(15, 23, 42, 0.18);
          }

          * { box-sizing: border-box; }

          body {
            margin: 0;
            min-height: 100vh;
            font-family: Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            color: var(--ink);
            background:
              radial-gradient(circle at top, rgba(14, 165, 233, 0.16), transparent 40%),
              linear-gradient(135deg, #f8fafc 0%, #e0f2fe 50%, #fdf2f8 100%);
          }

          a { color: inherit; }

          .shell {
            width: min(960px, calc(100% - 32px));
            margin: 0 auto;
            padding: 32px 0 48px;
          }

          .topbar {
            display: flex;
            justify-content: space-between;
            gap: 12px;
            align-items: center;
            margin-bottom: 28px;
            flex-wrap: wrap;
          }

          .back-link {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            text-decoration: none;
            font-weight: 700;
            color: #1d4ed8;
          }

          .eyebrow {
            margin: 0;
            font-size: 0.82rem;
            letter-spacing: 0.18em;
            text-transform: uppercase;
            color: var(--muted);
          }

          h1 {
            margin: 8px 0 12px;
            font-size: clamp(2.2rem, 5vw, 3.8rem);
            line-height: 1.05;
          }

          .subtitle {
            margin: 0;
            max-width: 44rem;
            font-size: 1.05rem;
            line-height: 1.6;
            color: var(--muted);
          }

          .app-grid {
            display: grid;
            grid-template-columns: minmax(0, 1.45fr) minmax(280px, 0.95fr);
            gap: 20px;
            margin-top: 28px;
          }

          .card {
            background: var(--surface);
            border: 1px solid var(--border);
            border-radius: 28px;
            box-shadow: var(--shadow);
            backdrop-filter: blur(16px);
          }

          .timer-card {
            padding: 28px;
            display: flex;
            flex-direction: column;
            gap: 24px;
          }

          .phase-badge {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 10px 16px;
            border-radius: 999px;
            font-weight: 700;
            background: rgba(239, 68, 68, 0.12);
            color: var(--focus);
            width: fit-content;
          }

          .phase-badge.break {
            background: rgba(15, 118, 110, 0.12);
            color: var(--break);
          }

          .timer-display {
            font-size: clamp(4rem, 12vw, 7rem);
            line-height: 1;
            letter-spacing: -0.06em;
            font-weight: 800;
            margin: 0;
          }

          .status-copy {
            margin: 0;
            min-height: 1.6em;
            color: var(--muted);
            font-size: 1rem;
          }

          .progress-shell {
            display: flex;
            flex-direction: column;
            gap: 10px;
          }

          .progress-meta {
            display: flex;
            justify-content: space-between;
            gap: 12px;
            font-size: 0.94rem;
            color: var(--muted);
          }

          .progress-track {
            position: relative;
            overflow: hidden;
            width: 100%;
            height: 16px;
            border-radius: 999px;
            background: rgba(148, 163, 184, 0.22);
          }

          .progress-fill {
            height: 100%;
            width: 0;
            border-radius: inherit;
            background: linear-gradient(90deg, var(--focus), #fb7185);
            transition: width 200ms linear, background 200ms ease;
          }

          .progress-fill.break {
            background: linear-gradient(90deg, var(--break), #14b8a6);
          }

          .controls {
            display: flex;
            flex-wrap: wrap;
            gap: 12px;
          }

          button {
            appearance: none;
            border: none;
            border-radius: 999px;
            padding: 14px 20px;
            font-size: 0.98rem;
            font-weight: 700;
            cursor: pointer;
            transition: transform 160ms ease, box-shadow 160ms ease, opacity 160ms ease;
          }

          button:hover:not(:disabled) {
            transform: translateY(-1px);
            box-shadow: 0 12px 24px rgba(15, 23, 42, 0.16);
          }

          button:disabled {
            opacity: 0.55;
            cursor: not-allowed;
          }

          .primary { background: #111827; color: white; }
          .secondary { background: #dbeafe; color: #1d4ed8; }
          .ghost { background: rgba(148, 163, 184, 0.18); color: #334155; }

          .stats {
            display: grid;
            grid-template-columns: repeat(2, minmax(0, 1fr));
            gap: 14px;
          }

          .stat {
            border-radius: 20px;
            padding: 18px;
            background: var(--surface-strong);
            border: 1px solid rgba(148, 163, 184, 0.22);
          }

          .stat-label {
            display: block;
            font-size: 0.82rem;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: var(--muted);
            margin-bottom: 10px;
          }

          .stat-value {
            display: block;
            font-size: 1.35rem;
            font-weight: 800;
          }

          .settings-card {
            padding: 24px;
          }

          .settings-card h2 {
            margin: 0 0 8px;
            font-size: 1.25rem;
          }

          .settings-card p {
            margin: 0 0 20px;
            color: var(--muted);
            line-height: 1.55;
          }

          .settings-group {
            display: grid;
            gap: 16px;
          }

          .setting-block {
            padding: 18px;
            border-radius: 20px;
            background: var(--surface-strong);
            border: 1px solid rgba(148, 163, 184, 0.22);
          }

          .setting-block h3 {
            margin: 0 0 14px;
            font-size: 1rem;
          }

          .setting-fields {
            display: grid;
            grid-template-columns: repeat(2, minmax(0, 1fr));
            gap: 12px;
          }

          label {
            display: grid;
            gap: 8px;
            font-size: 0.92rem;
            font-weight: 600;
          }

          input[type="number"] {
            width: 100%;
            border-radius: 14px;
            border: 1px solid rgba(148, 163, 184, 0.28);
            padding: 12px 14px;
            font-size: 1rem;
            font: inherit;
            color: inherit;
            background: white;
          }

          .helper-copy {
            margin-top: 16px;
            font-size: 0.92rem;
            color: var(--muted);
            line-height: 1.5;
          }

          @media (max-width: 820px) {
            .app-grid {
              grid-template-columns: 1fr;
            }

            .shell {
              width: min(100%, calc(100% - 20px));
              padding-top: 24px;
            }

            .timer-card,
            .settings-card {
              padding: 22px;
            }
          }
        </style>
      </head>
      <body>
        <main class="shell">
          <div class="topbar">
            <a class="back-link" href="/">← Back to Symphony dashboard</a>
            <p class="eyebrow">Standalone focus timer</p>
          </div>

          <section aria-label="Pomodoro intro">
            <p class="eyebrow">Pomodoro web app</p>
            <h1>Pomodoro Timer</h1>
            <p class="subtitle">
              Configure a focus session, start the countdown, and let the page roll into your
              break automatically. Changing the duration inputs resets the timer so every run stays
              predictable for demos and daily use.
            </p>
          </section>

          <section class="app-grid" aria-label="Pomodoro timer experience">
            <article class="card timer-card">
              <span id="phaseBadge" class="phase-badge">Focus session</span>
              <div>
                <p id="timerDisplay" class="timer-display" aria-live="polite">25:00</p>
                <p id="statusCopy" class="status-copy" aria-live="polite">
                  Set your durations, then start a focus session.
                </p>
              </div>

              <div class="progress-shell" aria-label="Timer progress">
                <div class="progress-meta">
                  <span>Progress</span>
                  <span id="progressLabel">0%</span>
                </div>
                <div class="progress-track" role="presentation">
                  <div id="progressFill" class="progress-fill"></div>
                </div>
              </div>

              <div class="controls" aria-label="Timer controls">
                <button id="startButton" class="primary" type="button">Start</button>
                <button id="pauseButton" class="secondary" type="button">Pause</button>
                <button id="resetButton" class="ghost" type="button">Reset</button>
              </div>

              <section class="stats" aria-label="Timer summary">
                <div class="stat">
                  <span class="stat-label">Current phase</span>
                  <span id="phaseValue" class="stat-value">Focus</span>
                </div>
                <div class="stat">
                  <span class="stat-label">Next up</span>
                  <span id="nextPhaseValue" class="stat-value">Break</span>
                </div>
                <div class="stat">
                  <span class="stat-label">Completed focus sessions</span>
                  <span id="completedCount" class="stat-value">0</span>
                </div>
                <div class="stat">
                  <span class="stat-label">Current duration</span>
                  <span id="durationValue" class="stat-value">25:00</span>
                </div>
              </section>
            </article>

            <aside class="card settings-card">
              <h2>Session settings</h2>
              <p>
                Use minutes and seconds so you can keep real pomodoro defaults or quickly dial in a
                short demo. Every phase must be at least 1 second long.
              </p>

              <div class="settings-group">
                <section class="setting-block" aria-labelledby="workSettingsTitle">
                  <h3 id="workSettingsTitle">Focus duration</h3>
                  <div class="setting-fields">
                    <label>
                      Minutes
                      <input id="workMinutes" type="number" min="0" max="180" step="1" value="25">
                    </label>
                    <label>
                      Seconds
                      <input id="workSeconds" type="number" min="0" max="59" step="1" value="0">
                    </label>
                  </div>
                </section>

                <section class="setting-block" aria-labelledby="breakSettingsTitle">
                  <h3 id="breakSettingsTitle">Break duration</h3>
                  <div class="setting-fields">
                    <label>
                      Minutes
                      <input id="breakMinutes" type="number" min="0" max="60" step="1" value="5">
                    </label>
                    <label>
                      Seconds
                      <input id="breakSeconds" type="number" min="0" max="59" step="1" value="0">
                    </label>
                  </div>
                </section>
              </div>

              <p class="helper-copy">
                Tip: for a quick walkthrough, try a 0m 3s focus session and a 0m 2s break. The app
                will pause if you hit reset, and it will continue automatically when switching
                between focus and break phases.
              </p>
            </aside>
          </section>
        </main>

        <script>
          (() => {
            const elements = {
              phaseBadge: document.getElementById('phaseBadge'),
              timerDisplay: document.getElementById('timerDisplay'),
              statusCopy: document.getElementById('statusCopy'),
              progressLabel: document.getElementById('progressLabel'),
              progressFill: document.getElementById('progressFill'),
              phaseValue: document.getElementById('phaseValue'),
              nextPhaseValue: document.getElementById('nextPhaseValue'),
              completedCount: document.getElementById('completedCount'),
              durationValue: document.getElementById('durationValue'),
              startButton: document.getElementById('startButton'),
              pauseButton: document.getElementById('pauseButton'),
              resetButton: document.getElementById('resetButton'),
              workMinutes: document.getElementById('workMinutes'),
              workSeconds: document.getElementById('workSeconds'),
              breakMinutes: document.getElementById('breakMinutes'),
              breakSeconds: document.getElementById('breakSeconds')
            };

            const state = {
              config: {
                work: 25 * 60,
                break: 5 * 60
              },
              phase: 'work',
              remainingSeconds: 25 * 60,
              isRunning: false,
              intervalId: null,
              endsAtMs: null,
              completedFocusSessions: 0,
              statusMessage: 'Set your durations, then start a focus session.'
            };

            const phaseMeta = {
              work: { label: 'Focus', badge: 'Focus session', next: 'Break', className: '' },
              break: { label: 'Break', badge: 'Break session', next: 'Focus', className: 'break' }
            };

            function formatSeconds(totalSeconds) {
              const safeSeconds = Math.max(0, totalSeconds);
              const minutes = Math.floor(safeSeconds / 60);
              const seconds = safeSeconds % 60;
              return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
            }

            function readPhaseDuration(prefix) {
              const minutesInput = elements[`${prefix}Minutes`];
              const secondsInput = elements[`${prefix}Seconds`];
              const minutes = Math.max(0, parseInt(minutesInput.value, 10) || 0);
              const seconds = Math.max(0, Math.min(59, parseInt(secondsInput.value, 10) || 0));

              minutesInput.value = String(minutes);
              secondsInput.value = String(seconds);

              return (minutes * 60) + seconds;
            }

            function syncDurations() {
              const workDuration = readPhaseDuration('work');
              const breakDuration = readPhaseDuration('break');

              if (workDuration <= 0 || breakDuration <= 0) {
                state.statusMessage = 'Each phase needs at least 1 second before the timer can run.';
                render();
                return false;
              }

              state.config.work = workDuration;
              state.config.break = breakDuration;
              return true;
            }

            function stopInterval() {
              if (state.intervalId) {
                window.clearInterval(state.intervalId);
                state.intervalId = null;
              }

              state.isRunning = false;
              state.endsAtMs = null;
            }

            function resetTimer(message = 'Timer reset to the start of your focus session.') {
              stopInterval();
              state.phase = 'work';
              state.remainingSeconds = state.config.work;
              state.statusMessage = message;
              render();
            }

            function startTimer() {
              if (!syncDurations() || state.isRunning) return;

              state.isRunning = true;
              state.endsAtMs = Date.now() + (state.remainingSeconds * 1000);
              state.statusMessage =
                state.phase === 'work'
                  ? 'Focus mode is running.'
                  : 'Break time is running.';

              state.intervalId = window.setInterval(tickTimer, 250);
              render();
            }

            function pauseTimer() {
              if (!state.isRunning) return;

              tickTimer();
              stopInterval();
              state.statusMessage = 'Timer paused.';
              render();
            }

            function advancePhase() {
              const finishedPhase = state.phase;

              if (finishedPhase === 'work') {
                state.completedFocusSessions += 1;
                state.phase = 'break';
                state.remainingSeconds = state.config.break;
                state.statusMessage = 'Focus complete. Starting your break.';
              } else {
                state.phase = 'work';
                state.remainingSeconds = state.config.work;
                state.statusMessage = 'Break complete. Time to focus again.';
              }

              state.endsAtMs = Date.now() + (state.remainingSeconds * 1000);
              render();
            }

            function tickTimer() {
              if (!state.isRunning || !state.endsAtMs) return;

              const nextRemaining = Math.max(0, Math.ceil((state.endsAtMs - Date.now()) / 1000));

              if (nextRemaining === 0) {
                advancePhase();
                return;
              }

              state.remainingSeconds = nextRemaining;
              render();
            }

            function render() {
              const meta = phaseMeta[state.phase];
              const totalPhaseSeconds = state.config[state.phase];
              const elapsedSeconds = Math.max(0, totalPhaseSeconds - state.remainingSeconds);
              const progressPercent =
                totalPhaseSeconds > 0
                  ? Math.min(100, Math.round((elapsedSeconds / totalPhaseSeconds) * 100))
                  : 0;

              elements.phaseBadge.textContent = meta.badge;
              elements.phaseBadge.className = `phase-badge ${meta.className}`.trim();
              elements.timerDisplay.textContent = formatSeconds(state.remainingSeconds);
              elements.statusCopy.textContent = state.statusMessage;
              elements.phaseValue.textContent = meta.label;
              elements.nextPhaseValue.textContent = meta.next;
              elements.completedCount.textContent = String(state.completedFocusSessions);
              elements.durationValue.textContent = formatSeconds(totalPhaseSeconds);
              elements.progressLabel.textContent = `${progressPercent}%`;
              elements.progressFill.style.width = `${progressPercent}%`;
              elements.progressFill.className = `progress-fill ${meta.className}`.trim();

              elements.startButton.disabled = state.isRunning;
              elements.pauseButton.disabled = !state.isRunning;
            }

            elements.startButton.addEventListener('click', startTimer);
            elements.pauseButton.addEventListener('click', pauseTimer);
            elements.resetButton.addEventListener('click', () => {
              if (syncDurations()) {
                resetTimer();
              }
            });

            function handleDurationUpdate() {
              if (syncDurations()) {
                resetTimer('Durations updated. Ready for a new focus session.');
              }
            }

            [elements.workMinutes, elements.workSeconds, elements.breakMinutes, elements.breakSeconds]
              .forEach((input) => {
                input.addEventListener('input', handleDurationUpdate);
              });

            resetTimer('Set your durations, then start a focus session.');
          })();
        </script>
      </body>
    </html>
    """
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
