defmodule RondoWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Rondo.
  """

  use Phoenix.LiveView, layout: {RondoWeb.Layouts, :app}

  alias RondoWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:selected_issue, nil)
      |> assign(:selected_run_index, 0)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
      schedule_chart_push()
      # Push initial chart data after a short delay so hooks are mounted
      Process.send_after(self(), :push_chart_data, 500)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:push_chart_data, socket) do
    schedule_chart_push()
    socket = push_dashboard_charts(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    # Only update panel data for live running issues, not archived views
    socket =
      case {socket.assigns.selected_issue, socket.assigns[:selected_runs]} do
        {nil, _} ->
          socket

        {_identifier, runs} when is_list(runs) ->
          # Viewing an archived run — don't overwrite with live data
          socket

        {identifier, _} ->
          # Viewing a live running issue — keep it updated
          entry = find_issue_entry(socket.assigns.payload, identifier)
          if entry, do: assign(socket, :selected_issue_data, entry), else: socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_issue", %{"identifier" => identifier}, socket) do
    entry = find_issue_entry(socket.assigns.payload, identifier)

    socket =
      socket
      |> assign(:selected_issue, identifier)
      |> assign(:selected_issue_data, entry)
      |> assign(:selected_runs, nil)
      |> assign(:selected_run_index, 0)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_archived", %{"identifier" => identifier}, socket) do
    archived = Map.get(socket.assigns.payload, :archived, [])
    group = Enum.find(archived, &(&1.issue_identifier == identifier))

    if group do
      latest_index = length(group.runs) - 1
      latest_run = List.last(group.runs)
      run_with_log = load_run_event_log(latest_run)

      {:noreply,
       socket
       |> assign(:selected_issue, identifier)
       |> assign(:selected_issue_data, run_with_log)
       |> assign(:selected_run_index, latest_index)
       |> assign(:selected_runs, group.runs)
       |> push_run_charts(group.runs)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_run", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    runs = socket.assigns[:selected_runs] || []
    run = Enum.at(runs, index)

    if run do
      run_with_log = load_run_event_log(run)

      {:noreply,
       socket
       |> assign(:selected_issue_data, run_with_log)
       |> assign(:selected_run_index, index)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_issue, nil)
     |> assign(:selected_issue_data, nil)
     |> assign(:selected_runs, nil)
     |> assign(:selected_run_index, 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Rondo Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Rondo runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <label class="theme-switch" id="theme-toggle" phx-hook="ThemeToggle" phx-update="ignore">
              <input type="checkbox" onclick="RondoTheme.toggle()" />
              <span class="theme-switch-track">
                <svg class="theme-icon-sun" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>
                <svg class="theme-icon-moon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>
              </span>
            </label>
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
            <p class="metric-value numeric"><%= format_int(@payload.claude_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.claude_totals.input_tokens) %> / Out <%= format_int(@payload.claude_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Claude runtime across completed and active sessions.</p>
          </article>
        </section>

        <div class="chart-grid">
          <div class="chart-card">
            <p class="chart-card-title">Token usage</p>
            <div class="chart-wrap">
              <canvas id="token-chart" phx-hook="TokenChart" phx-update="ignore"></canvas>
            </div>
          </div>
          <div class="chart-card">
            <p class="chart-card-title">Active sessions</p>
            <div class="chart-wrap">
              <canvas id="session-chart" phx-hook="SessionChart" phx-update="ignore"></canvas>
            </div>
          </div>
          <div class="chart-card chart-grid-full">
            <p class="chart-card-title">Archived runs by ticket (tokens)</p>
            <div class="chart-wrap">
              <canvas id="outcome-chart" phx-hook="OutcomeChart" phx-update="ignore"></canvas>
            </div>
          </div>
        </div>

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
                    <th>Claude update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={entry <- @payload.running}
                    class={"data-table-row #{if @selected_issue == entry.issue_identifier, do: "data-table-row-selected", else: ""}"}
                    phx-click="select_issue"
                    phx-value-identifier={entry.issue_identifier}
                    style="cursor: pointer;"
                  >
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"} onclick="event.stopPropagation()">JSON</a>
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
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
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

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Archived runs</h2>
              <p class="section-copy">Completed agent sessions. Click to view transcripts.</p>
            </div>
          </div>

          <%= if (@payload[:archived] || []) == [] do %>
            <p class="empty-state">No archived runs yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 580px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Runs</th>
                    <th>Last result</th>
                    <th>Total tokens</th>
                    <th>Last run</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={group <- @payload.archived}
                    class={"data-table-row #{if @selected_issue == group.issue_identifier, do: "data-table-row-selected", else: ""}"}
                    phx-click="select_archived"
                    phx-value-identifier={group.issue_identifier}
                    style="cursor: pointer;"
                  >
                    <td>
                      <span class="issue-id"><%= group.issue_identifier %></span>
                    </td>
                    <td class="numeric"><%= group.run_count %></td>
                    <td>
                      <span class={exit_reason_class(group.latest_result)}>
                        <%= group.latest_result %>
                      </span>
                    </td>
                    <td class="numeric"><%= format_int(group.total_tokens) %></td>
                    <td class="mono muted" style="font-size: 12px;"><%= format_finished_at(group.latest_finished_at) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>

    <%= if @selected_issue do %>
      <div class="panel-overlay" phx-click="close_panel"></div>
      <aside class="panel-slide">
        <div class="panel-header">
          <div>
            <h2 class="panel-title"><%= @selected_issue %></h2>
            <p class="panel-subtitle">
              <%= if @selected_issue_data && @selected_issue_data[:finished_at] do %>
                Archived run
              <% else %>
                Live agent event stream
              <% end %>
            </p>
          </div>
          <button type="button" class="panel-close" phx-click="close_panel">&times;</button>
        </div>

        <%= if @selected_runs && length(@selected_runs) > 1 do %>
          <div class="run-tabs">
            <%= for {run, idx} <- Enum.with_index(@selected_runs) do %>
              <button
                type="button"
                class={"run-tab #{if idx == @selected_run_index, do: "run-tab-active", else: ""}"}
                phx-click="select_run"
                phx-value-index={idx}
              >
                Run <%= idx + 1 %> · <%= format_event_time(run.started_at) %>
              </button>
            <% end %>
          </div>
        <% end %>

        <%= if @selected_issue_data do %>
          <div class="panel-metrics">
            <div class="panel-metric">
              <span class="panel-metric-label">State</span>
              <span class={state_badge_class(@selected_issue_data[:state] || "n/a")}><%= @selected_issue_data[:state] || "n/a" %></span>
            </div>
            <div class="panel-metric">
              <span class="panel-metric-label">
                <%= if @selected_issue_data[:finished_at], do: "Duration", else: "Runtime" %>
              </span>
              <span class="numeric">
                <%= if @selected_issue_data[:finished_at] do %>
                  <%= format_duration(@selected_issue_data.started_at, @selected_issue_data.finished_at) %>
                <% else %>
                  <%= format_runtime_and_turns(@selected_issue_data.started_at, @selected_issue_data.turn_count, @now) %>
                <% end %>
              </span>
            </div>
            <div class="panel-metric">
              <span class="panel-metric-label">Tokens</span>
              <span class="numeric"><%= format_int(@selected_issue_data.tokens.total_tokens) %></span>
            </div>
            <div class="panel-metric">
              <%= if @selected_issue_data[:exit_reason] do %>
                <span class="panel-metric-label">Result</span>
                <span class={exit_reason_class(@selected_issue_data.exit_reason)}><%= @selected_issue_data.exit_reason %></span>
              <% else %>
                <span class="panel-metric-label">Session</span>
                <span class="mono" style="font-size: 11px;"><%= @selected_issue_data[:session_id] || "n/a" %></span>
              <% end %>
            </div>
          </div>

          <%= if @selected_runs && length(@selected_runs) > 0 do %>
            <div class="panel-charts">
              <div>
                <p class="chart-card-title">Tokens per run</p>
                <div class="panel-chart-wrap">
                  <canvas id="run-token-chart" phx-hook="RunTokenChart" phx-update="ignore"></canvas>
                </div>
              </div>
              <div>
                <p class="chart-card-title">Duration per run</p>
                <div class="panel-chart-wrap">
                  <canvas id="run-duration-chart" phx-hook="RunDurationChart" phx-update="ignore"></canvas>
                </div>
              </div>
            </div>
          <% end %>

          <div class="panel-stream-header">
            <span class="panel-metric-label">Event stream</span>
            <span class="muted" style="font-size: 11px;"><%= length(@selected_issue_data.event_log) %> events</span>
          </div>

          <%= if @selected_issue_data.event_log == [] do %>
            <p class="empty-state">Waiting for agent activity...</p>
          <% else %>
            <div class="event-stream" id="event-stream" phx-hook="ScrollBottom">
              <div :for={entry <- @selected_issue_data.event_log} class="event-row">
                <span class={event_type_class(entry.event)}>
                  <%= if tool_event?(entry.event) do %><svg class="event-icon" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg><% end %><%= entry.event %>
                </span>
                <span class="event-row-message"><%= render_event_message(entry.message) %></span>
              </div>
            </div>
          <% end %>
        <% else %>
          <p class="empty-state">Issue not currently running.</p>
        <% end %>
      </aside>
    <% end %>
    """
  end

  defp load_run_event_log(run) do
    identifier = run[:issue_identifier]
    filename = run[:filename]

    if identifier && filename do
      case Rondo.Orchestrator.load_archived_run(identifier, filename) do
        {:ok, full_entry} ->
          event_log = RondoWeb.Presenter.format_event_log_public(Map.get(full_entry, :event_log, []))
          Map.put(run, :event_log, event_log)

        _ ->
          Map.put(run, :event_log, [])
      end
    else
      Map.put(run, :event_log, [])
    end
  end

  defp find_issue_entry(payload, identifier) do
    running = Map.get(payload, :running, [])
    Enum.find(running, &(&1.issue_identifier == identifier))
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || Rondo.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.claude_totals.seconds_running || 0
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

  defp format_event_time(nil), do: ""

  defp format_event_time(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso_string
    end
  end

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

  defp format_duration(started_at, finished_at) when is_binary(started_at) and is_binary(finished_at) do
    with {:ok, s, _} <- DateTime.from_iso8601(started_at),
         {:ok, f, _} <- DateTime.from_iso8601(finished_at) do
      format_runtime_seconds(DateTime.diff(f, s, :second))
    else
      _ -> "n/a"
    end
  end

  defp format_duration(_, _), do: "n/a"

  defp format_finished_at(nil), do: ""

  defp format_finished_at(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso_string
    end
  end

  defp exit_reason_class("completed"), do: "state-badge state-badge-active"
  defp exit_reason_class(_), do: "state-badge state-badge-danger"

  defp render_event_message(nil), do: ""
  defp render_event_message(""), do: ""

  defp render_event_message(text) when is_binary(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(~r/`([^`]+)`/, "<code>\\1</code>")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    |> Phoenix.HTML.raw()
  end

  @tool_events ~w(linear github bash read write edit grep glob agent tool)a

  defp tool_event?(event), do: event in @tool_events

  defp event_type_class(event) do
    base = "event-row-type mono"

    case event do
      :linear -> "#{base} event-type-linear"
      :github -> "#{base} event-type-github"
      e when e in [:bash, :read, :write, :edit, :grep, :glob, :agent, :tool] -> "#{base} event-type-tool"
      e when e in [:error, :fail] -> "#{base} event-type-danger"
      e when e in [:session_started, :claude_starting] -> "#{base} event-type-success"
      e when e in [:result] -> "#{base} event-type-muted"
      :rate_limit -> "#{base} event-type-danger"
      _ -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  @chart_push_ms 10_000
  defp schedule_chart_push do
    Process.send_after(self(), :push_chart_data, @chart_push_ms)
  end

  defp push_dashboard_charts(socket) do
    archived = Map.get(socket.assigns.payload, :archived, [])

    socket
    |> push_event("update-token-chart", Presenter.token_timeseries())
    |> push_event("update-session-chart", Presenter.session_timeseries())
    |> push_event("update-outcome-chart", Presenter.run_outcomes(archived))
  end

  defp push_run_charts(socket, runs) when is_list(runs) do
    socket
    |> push_event("update-run-token-chart", Presenter.run_token_comparison(runs))
    |> push_event("update-run-duration-chart", Presenter.run_duration_comparison(runs))
  end

  defp push_run_charts(socket, _), do: socket

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
