defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    payload = load_payload()

    socket =
      socket
      |> assign(:payload, payload)
      |> assign(:selected_issue_id, nil)
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    payload = load_payload()

    {:noreply,
     socket
     |> assign(:payload, payload)
     |> assign(:selected_issue_id, retained_selected_issue_id(payload, socket.assigns[:selected_issue_id]))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("select_session", %{"issue-id" => issue_id}, socket) do
    selected_issue_id =
      if running_issue_id?(socket.assigns.payload, issue_id) do
        issue_id
      end

    {:noreply, assign(socket, :selected_issue_id, selected_issue_id)}
  end

  def handle_event("clear_selected_session", _params, socket) do
    {:noreply, assign(socket, :selected_issue_id, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={entry <- @payload.running}
                    id={"running-session-#{running_entry_key(entry)}"}
                    class={running_row_class(entry, @selected_issue_id)}
                    phx-click="select_session"
                    phx-value-issue-id={running_entry_key(entry)}
                  >
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a
                          class="issue-link"
                          href={"/api/v1/#{entry.issue_identifier}"}
                          onclick="event.stopPropagation();"
                        >JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="event.stopPropagation(); navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <% selected_entry = selected_running_entry(@payload, @selected_issue_id) %>
            <%= if selected_entry do %>
              <section class="agent-detail-panel" id={"agent-detail-#{running_entry_key(selected_entry)}"}>
                <div class="agent-detail-header">
                  <div>
                    <p class="detail-kicker">Agent details</p>
                    <h3 class="agent-detail-title"><%= selected_entry.issue_identifier %></h3>
                    <p class="section-copy">
                      <%= selected_entry.execution.current_stage %> · <%= selected_entry.execution.completed_count %> completed / <%= selected_entry.execution.pending_count %> pending
                    </p>
                  </div>
                  <button type="button" class="subtle-button" phx-click="clear_selected_session">Close</button>
                </div>

                <div class="agent-stage-band">
                  <span class="detail-label">Current stage</span>
                  <strong><%= selected_entry.execution.current_stage %></strong>
                  <span class="muted">
                    Last update: <%= selected_entry.last_message || to_string(selected_entry.last_event || "n/a") %>
                  </span>
                </div>

                <div class="agent-detail-grid">
                  <div>
                    <span class="detail-label">State</span>
                    <strong><%= selected_entry.state %></strong>
                  </div>
                  <div>
                    <span class="detail-label">Runtime / turns</span>
                    <strong class="numeric"><%= format_runtime_and_turns(selected_entry.started_at, selected_entry.turn_count, @now) %></strong>
                  </div>
                  <div>
                    <span class="detail-label">Session</span>
                    <span class="mono"><%= selected_entry.session_id || "n/a" %></span>
                  </div>
                  <div>
                    <span class="detail-label">Worker</span>
                    <span><%= selected_entry.worker_host || "local" %></span>
                  </div>
                  <div class="detail-grid-wide">
                    <span class="detail-label">Workspace</span>
                    <span class="mono"><%= selected_entry.workspace_path || "n/a" %></span>
                  </div>
                </div>

                <div class="agent-detail-columns">
                  <div>
                    <h4 class="detail-subtitle">Execution checklist</h4>
                    <ol class="execution-steps">
                      <li :for={step <- selected_entry.execution.steps} class={execution_step_class(step.status)}>
                        <span class="step-state"><%= step_status_label(step.status) %></span>
                        <div class="step-copy">
                          <strong><%= step.label %></strong>
                          <span class="muted"><%= step.detail %></span>
                        </div>
                      </li>
                    </ol>
                  </div>

                  <div>
                    <h4 class="detail-subtitle">Recent Codex events</h4>
                    <%= if selected_entry.recent_events == [] do %>
                      <p class="empty-state empty-state-compact">No timestamped Codex events captured yet.</p>
                    <% else %>
                      <div class="event-list">
                        <div :for={event <- recent_events_for_display(selected_entry.recent_events)} class="event-row">
                          <span class="mono event-time"><%= event.at %></span>
                          <span class="event-message">
                            <%= event.message || to_string(event.event || "n/a") %>
                          </span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              </section>
            <% else %>
              <p class="detail-hint">Click a running session to inspect live execution details.</p>
            <% end %>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp selected_running_entry(%{running: running}, selected_issue_id) when is_list(running) and is_binary(selected_issue_id) do
    Enum.find(running, &(running_entry_key(&1) == selected_issue_id))
  end

  defp selected_running_entry(_payload, _selected_issue_id), do: nil

  defp retained_selected_issue_id(payload, selected_issue_id) do
    if running_issue_id?(payload, selected_issue_id) do
      selected_issue_id
    end
  end

  defp running_issue_id?(%{running: running}, issue_id) when is_list(running) and is_binary(issue_id) do
    Enum.any?(running, &(running_entry_key(&1) == issue_id))
  end

  defp running_issue_id?(_payload, _issue_id), do: false

  defp running_entry_key(entry) do
    Map.get(entry, :issue_id) || Map.get(entry, :issue_identifier) || "unknown"
  end

  defp running_row_class(entry, selected_issue_id) do
    base = "selectable-row"

    if running_entry_key(entry) == selected_issue_id do
      "#{base} selectable-row-selected"
    else
      base
    end
  end

  defp recent_events_for_display(events) when is_list(events) do
    events
    |> Enum.reverse()
    |> Enum.take(8)
  end

  defp recent_events_for_display(_events), do: []

  defp execution_step_class(status), do: "execution-step execution-step-#{status}"
  defp step_status_label("done"), do: "Done"
  defp step_status_label("active"), do: "Now"
  defp step_status_label(_status), do: "Next"

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
