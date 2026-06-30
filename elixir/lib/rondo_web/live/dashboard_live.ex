defmodule RondoWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Rondo.
  """

  use Phoenix.LiveView, layout: {RondoWeb.Layouts, :app}

  alias RondoWeb.{ArchivedRuns, Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:log_filters, default_log_filters())
      |> assign(:event_filters, default_event_filters())
      |> assign(:selected_event_index, 0)
      |> assign(:selected_event_mode, :pretty)
      |> assign(:selected_issue, nil)
      |> assign(:selected_issue_data, nil)
      |> assign(:selected_runs, nil)
      |> assign(:selected_run_index, 0)
      |> assign(:archived_filters, ArchivedRuns.default_filters())

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
      |> assign(:selected_run_projection, selected_run_projection_for(socket.assigns.payload, entry))
      |> assign(:selected_event_index, 0)
      |> assign(:selected_event_mode, :pretty)
      |> assign(:event_filters, default_event_filters())

    {:noreply, socket}
  end

  @impl true
  def handle_event("submit_guidance", %{"issue-id" => issue_id, "guidance" => guidance}, socket) do
    socket =
      case Rondo.Orchestrator.submit_guidance(issue_id, guidance) do
        {:ok, _response} -> socket
        {:error, reason} -> put_flash(socket, :error, "Failed to submit guidance: #{inspect(reason)}")
        :unavailable -> put_flash(socket, :error, "Failed to submit guidance: orchestrator unavailable")
      end

    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

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
       |> assign(:selected_run_projection, selected_run_projection_for(socket.assigns.payload, latest_run))
       |> assign(:selected_event_index, 0)
       |> assign(:selected_event_mode, :pretty)
       |> assign(:event_filters, default_event_filters())
       |> push_run_charts(group.runs)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_archived_run", %{"identifier" => identifier, "filename" => filename}, socket) do
    archived = Map.get(socket.assigns.payload, :archived, [])
    group = Enum.find(archived, &(&1.issue_identifier == identifier))

    case group do
      %{runs: runs} when is_list(runs) ->
        selected_index = Enum.find_index(runs, &(&1.filename == filename)) || max(length(runs) - 1, 0)
        selected_run = Enum.at(runs, selected_index)
        run_with_log = load_run_event_log(selected_run)

        {:noreply,
         socket
         |> assign(:selected_issue, identifier)
         |> assign(:selected_issue_data, run_with_log)
         |> assign(:selected_run_index, selected_index)
         |> assign(:selected_runs, runs)
         |> push_run_charts(runs)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_archived", params, socket) do
    filters = socket.assigns.archived_filters |> ArchivedRuns.merge_filters(params) |> Map.put(:page, 1)
    {:noreply, assign(socket, :archived_filters, filters)}
  end

  @impl true
  def handle_event("sort_archived", %{"field" => field}, socket) do
    {:noreply, assign(socket, :archived_filters, ArchivedRuns.next_sort(socket.assigns.archived_filters, field))}
  end

  @impl true
  def handle_event("page_archived", %{"page" => page}, socket) do
    filters = ArchivedRuns.merge_filters(socket.assigns.archived_filters, %{"page" => page})
    {:noreply, assign(socket, :archived_filters, filters)}
  end

  @impl true
  def handle_event("reset_archived_filters", _params, socket) do
    {:noreply, assign(socket, :archived_filters, ArchivedRuns.default_filters())}
  end

  @impl true
  def handle_event("show_archived_failures", _params, socket) do
    filters = %{socket.assigns.archived_filters | status: "failed", page: 1, sort_by: "ended", sort_dir: "desc"}
    {:noreply, assign(socket, :archived_filters, filters)}
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
       |> assign(:selected_run_index, index)
       |> assign(:selected_run_projection, selected_run_projection_for(socket.assigns.payload, run))
       |> assign(:selected_event_index, 0)
       |> assign(:selected_event_mode, :pretty)
       |> assign(:event_filters, default_event_filters())}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_logs", params, socket) do
    {:noreply, assign(socket, :log_filters, merge_log_filters(socket.assigns.log_filters, params))}
  end

  @impl true
  def handle_event("sort_logs", %{"field" => field}, socket) do
    filters = socket.assigns.log_filters
    direction = if filters.sort_by == field, do: toggle_sort_direction(filters.sort_dir), else: "desc"

    {:noreply, assign(socket, :log_filters, Map.merge(filters, %{sort_by: field, sort_dir: direction}))}
  end

  @impl true
  def handle_event("filter_events", params, socket) do
    {:noreply,
     socket
     |> assign(:event_filters, merge_event_filters(socket.assigns.event_filters, params))
     |> assign(:selected_event_index, 0)}
  end

  @impl true
  def handle_event("select_event", %{"index" => index_str}, socket) do
    {:noreply, assign(socket, :selected_event_index, String.to_integer(index_str))}
  end

  @impl true
  def handle_event("toggle_event_mode", _params, socket) do
    mode = if socket.assigns.selected_event_mode == :raw, do: :pretty, else: :raw
    {:noreply, assign(socket, :selected_event_mode, mode)}
  end

  @impl true
  def handle_event("close_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_issue, nil)
     |> assign(:selected_issue_data, nil)
     |> assign(:selected_runs, nil)
     |> assign(:selected_run_index, 0)
     |> assign(:selected_run_projection, nil)
     |> assign(:selected_event_index, 0)
     |> assign(:selected_event_mode, :pretty)
     |> assign(:event_filters, default_event_filters())}
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
            <p class="metric-detail">Total runtime across completed and active sessions.</p>
          </article>
        </section>

        <div class="chart-grid">
          <div class="chart-card">
            <p class="chart-card-title">Provider mix</p>
            <div class="model-usage-grid">
              <%= if Map.get(@payload.model_usage, :by_provider) |> map_size() == 0 do %>
                <div class="model-usage-item">
                  <span class="model-usage-provider">No provider data</span>
                  <span class="model-usage-detail">Waiting for runs to resolve model routing.</span>
                </div>
              <% else %>
                <%= for {provider, info} <- @payload.model_usage.by_provider |> Enum.sort_by(fn {_provider, info} -> info.run_count end, :desc) do %>
                  <div class="model-usage-item">
                    <span class="model-usage-provider"><%= provider_label(provider) %></span>
                    <span class="model-usage-pct"><%= format_model_pct(info.run_pct) %></span>
                    <span class="model-usage-detail"><%= info.run_count %> run<%= if info.run_count != 1, do: "s" %> · <%= format_int(info.token_count) %> tokens</span>
                  </div>
                <% end %>
              <% end %>
            </div>
            <%= if map_size(@payload.model_usage.by_model) > 0 do %>
              <details style="margin-top: 8px; font-size: 11px;">
                <summary style="cursor: pointer; color: var(--text-muted);">By model (<%= map_size(@payload.model_usage.by_model) %> models)</summary>
                <div style="margin-top: 6px; display: flex; flex-direction: column; gap: 2px;">
                  <%= for {model, info} <- @payload.model_usage.by_model |> Enum.sort_by(&elem(&1, 1).run_count, :desc) do %>
                    <span class="muted"><%= model %>: <%= info.run_count %> run<%= if info.run_count != 1, do: "s" %> (<%= format_model_pct(pct_of(info.run_count, @payload.model_usage.total_runs)) %>)</span>
                  <% end %>
                </div>
              </details>
            <% end %>
          </div>
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

        <% log_rows = dashboard_log_rows(@payload, @log_filters) %>
        <section class="section-card logs-section">
          <div class="section-header logs-section-header">
            <div>
              <h2 class="section-title">Logs</h2>
              <p class="section-copy">Dense run history with live, paused, retrying, and archived visibility.</p>
            </div>
            <div class="logs-summary">
              <span class="state-badge state-badge-active"><%= length(log_rows) %> rows</span>
              <span class="muted">Sort: <%= @log_filters.sort_by %> · <%= @log_filters.sort_dir %></span>
            </div>
          </div>

          <form class="logs-toolbar" phx-change="filter_logs">
            <label class="logs-control">
              <span class="logs-control-label">Search</span>
              <input
                type="search"
                name="query"
                value={@log_filters.query}
                placeholder="Search issues, models, providers, messages"
                class="logs-search-input"
                phx-debounce="250"
              />
            </label>

            <label class="logs-control">
              <span class="logs-control-label">Status</span>
              <select name="status" class="logs-select">
                <option value="all" selected={@log_filters.status == "all"}>All</option>
                <option value="active" selected={@log_filters.status == "active"}>Active</option>
                <option value="running" selected={@log_filters.status == "running"}>Running</option>
                <option value="paused" selected={@log_filters.status == "paused"}>Paused</option>
                <option value="retrying" selected={@log_filters.status == "retrying"}>Retrying</option>
                <option value="archived" selected={@log_filters.status == "archived"}>Archived</option>
              </select>
            </label>

            <label class="logs-control">
              <span class="logs-control-label">Date</span>
              <select name="window" class="logs-select">
                <option value="all" selected={@log_filters.window == "all"}>All time</option>
                <option value="24h" selected={@log_filters.window == "24h"}>Last 24h</option>
                <option value="7d" selected={@log_filters.window == "7d"}>Last 7d</option>
                <option value="30d" selected={@log_filters.window == "30d"}>Last 30d</option>
              </select>
            </label>
          </form>

          <div class="table-wrap">
            <table class="data-table logs-table">
              <colgroup>
                <col style="width: 9rem;" />
                <col style="width: 13rem;" />
                <col style="width: 10rem;" />
                <col style="width: 7rem;" />
                <col style="width: 6.5rem;" />
                <col style="width: 6.5rem;" />
                <col style="width: 6.5rem;" />
                <col style="width: 7rem;" />
                <col style="width: 8rem;" />
                <col style="width: 10rem;" />
                <col style="width: 5rem;" />
              </colgroup>
              <thead>
                <tr>
                  <th><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="date">Date <%= sort_indicator(@log_filters, "date") %></button></th>
                  <th><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="model">Model <%= sort_indicator(@log_filters, "model") %></button></th>
                  <th><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="provider">Provider <%= sort_indicator(@log_filters, "provider") %></button></th>
                  <th><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="app">App <%= sort_indicator(@log_filters, "app") %></button></th>
                  <th><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="input_tokens">Input <%= sort_indicator(@log_filters, "input_tokens") %></button></th>
                  <th><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="output_tokens">Output <%= sort_indicator(@log_filters, "output_tokens") %></button></th>
                  <th><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="cost">Cost <%= sort_indicator(@log_filters, "cost") %></button></th>
                  <th><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="speed">Speed <%= sort_indicator(@log_filters, "speed") %></button></th>
                  <th><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="finish">Finish <%= sort_indicator(@log_filters, "finish") %></button></th>
                  <th>Source</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- log_rows}
                  class={"data-table-row #{if log_row_selected?(@selected_issue, row), do: "data-table-row-selected", else: ""}"}
                  phx-click={if row.kind == :archived, do: "select_archived", else: "select_issue"}
                  phx-value-identifier={row.identifier}
                  style="cursor: pointer;"
                >
                  <td>
                    <div class="detail-stack">
                      <span class="mono"><%= log_row_date(row) %></span>
                      <span class={log_row_status_class(row)}><%= log_row_kind_label(row) %></span>
                    </div>
                  </td>
                  <td>
                    <div class="detail-stack">
                      <span class="mono"><%= log_row_model(row) %></span>
                      <span class="muted event-meta"><%= log_row_message(row) %></span>
                    </div>
                  </td>
                  <td><span class={provider_badge_class(log_row_provider(row))}><%= log_row_provider(row) || "n/a" %></span></td>
                  <td class="mono"><%= log_row_app(row) || "n/a" %></td>
                  <td class="numeric"><%= format_int(log_row_input_tokens(row)) %></td>
                  <td class="numeric"><%= format_int(log_row_output_tokens(row)) %></td>
                  <td class="numeric"><%= format_cost(log_row_cost(row)) %></td>
                  <td class="numeric"><%= format_speed(log_row_speed(row)) %></td>
                  <td><span class={log_row_finish_class(row)}><%= log_row_finish(row) || "n/a" %></span></td>
                  <td>
                    <a class="issue-link" href={log_row_source_link(row)} onclick="event.stopPropagation()">JSON</a>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Needs guidance</h2>
              <p class="section-copy">Paused runs waiting for operator guidance before they can continue.</p>
            </div>
          </div>

          <%= if Map.get(@payload, :needs_guidance, []) == [] do %>
            <p class="empty-state">No runs need guidance.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Severity</th>
                    <th>Waiting on</th>
                    <th>Blocked since</th>
                    <th>Last turn</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={entry <- @payload.needs_guidance}
                    class={"data-table-row #{if @selected_issue == entry.issue_identifier, do: "data-table-row-selected", else: ""}"}
                    phx-click="select_issue"
                    phx-value-identifier={entry.issue_identifier}
                    style="cursor: pointer;"
                  >
                    <% quick_response = quick_guidance_response(entry) %>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"} onclick="event.stopPropagation()">JSON</a>
                        <%= render_entry_links(%{entry: entry, compact: true}) %>
                      </div>
                    </td>
                    <td>
                      <span class={guidance_severity_class(Map.get(entry, :guidance_severity))}>
                        <%= Map.get(entry, :guidance_severity) || "warning" %>
                      </span>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text"><%= guidance_waiting_label(entry) %></span>
                        <span class="muted event-meta"><%= guidance_waiting_meta(entry) %></span>
                        <%= if paused_claim_status(entry) do %>
                          <span class="muted event-meta"><%= paused_claim_status(entry) %></span>
                        <% end %>
                      </div>
                    </td>
                    <td class="mono"><%= Map.get(entry, :paused_at) || "n/a" %></td>
                    <td class="numeric"><%= length(Map.get(entry, :event_log, []) || []) %> events</td>
                    <td>
                      <%= if quick_response do %>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="submit_guidance"
                          phx-value-issue-id={entry.issue_id}
                          phx-value-guidance={Map.get(quick_response, :guidance) || Map.get(quick_response, :id)}
                          onclick="event.stopPropagation()"
                        >
                          <%= Map.get(quick_response, :label) || Map.get(quick_response, :id) %>
                        </button>
                      <% end %>
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
                    <th>Latest update</th>
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
                        <%= render_entry_links(%{entry: entry, compact: true}) %>
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

        <% archived_view = archived_table_view(@payload, @archived_filters) %>
        <section class="section-card archived-runs-card">
          <div class="section-header archived-section-header">
            <div>
              <h2 class="section-title">Archived runs</h2>
              <p class="section-copy">Searchable run history. Select any row to open the same detail inspector used for active runs.</p>
            </div>
            <div class="archive-summary-strip">
              <span class="state-badge"><%= archived_view.total %> matching</span>
              <button
                :if={archived_view.recent_failures != []}
                type="button"
                class="subtle-button"
                phx-click="show_archived_failures"
              >
                <%= length(archived_view.recent_failures) %> recent failures
              </button>
            </div>
          </div>

          <%= if (@payload[:archived_table] || []) == [] do %>
            <p class="empty-state">No archived runs yet.</p>
          <% else %>
            <form class="archive-filter-bar" phx-change="filter_archived">
              <input type="hidden" name="page_size" value={archived_view.page_size} />
              <input class="archive-filter-input" type="search" name="search" value={archived_view.filters.search} placeholder="Search issue, title, repo, model, result" />
              <select name="status" class="archive-filter-select">
                <option value="all" selected={archived_view.filters.status == "all"}>All statuses</option>
                <option :for={status <- archived_view.options.statuses} value={status} selected={archived_view.filters.status == status}><%= status %></option>
              </select>
              <select name="model" class="archive-filter-select">
                <option value="all" selected={archived_view.filters.model == "all"}>All models</option>
                <option :for={model <- archived_view.options.models} value={model} selected={archived_view.filters.model == model}><%= model %></option>
              </select>
              <select name="project" class="archive-filter-select">
                <option value="all" selected={archived_view.filters.project == "all"}>All projects/repos</option>
                <option :for={project <- archived_view.options.projects} value={project} selected={archived_view.filters.project == project}><%= project %></option>
              </select>
              <label class="archive-date-filter">
                From
                <input type="date" name="date_from" value={archived_view.filters.date_from} />
              </label>
              <label class="archive-date-filter">
                To
                <input type="date" name="date_to" value={archived_view.filters.date_to} />
              </label>
              <button type="button" class="subtle-button" phx-click="reset_archived_filters">Reset</button>
            </form>

            <%= if archived_view.rows == [] do %>
              <p class="empty-state">No archived runs match the current filters.</p>
            <% else %>
              <div class="table-wrap archive-table-wrap">
                <table class="data-table archive-table">
                  <thead>
                    <tr>
                      <th><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="issue">Issue <%= sort_indicator(archived_view.filters, "issue") %></button></th>
                      <th><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="project">Project / repo <%= sort_indicator(archived_view.filters, "project") %></button></th>
                      <th><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="status">State / outcome <%= sort_indicator(archived_view.filters, "status") %></button></th>
                      <th><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="started">Started <%= sort_indicator(archived_view.filters, "started") %></button></th>
                      <th><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="ended">Ended <%= sort_indicator(archived_view.filters, "ended") %></button></th>
                      <th><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="duration">Duration <%= sort_indicator(archived_view.filters, "duration") %></button></th>
                      <th><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="model">Model / provider <%= sort_indicator(archived_view.filters, "model") %></button></th>
                      <th><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="tokens">Tokens / cost <%= sort_indicator(archived_view.filters, "tokens") %></button></th>
                      <th>Links</th>
                      <th><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="result">Last result <%= sort_indicator(archived_view.filters, "result") %></button></th>
                      <th>Activity</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={run <- archived_view.rows}
                      class={archived_row_class(run, @selected_issue, @selected_issue_data)}
                      phx-click="select_archived_run"
                      phx-value-identifier={run.issue_identifier}
                      phx-value-filename={run.filename}
                      style="cursor: pointer;"
                    >
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= run.issue_identifier %></span>
                          <span :if={run.issue_title} class="muted archive-title" title={run.issue_title}><%= run.issue_title %></span>
                          <a class="issue-link" href={"/api/v1/#{run.issue_identifier}"} onclick="event.stopPropagation()">JSON</a>
                          <%= render_entry_links(%{entry: run, compact: true}) %>
                        </div>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <span><%= run.project || "n/a" %></span>
                          <span class="muted event-meta"><%= run.repo || "n/a" %></span>
                        </div>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <span class={exit_reason_class(run.exit_reason)}><%= run.status %></span>
                          <span class="muted event-meta"><%= run.outcome || "n/a" %></span>
                        </div>
                      </td>
                      <td class="mono muted"><%= format_archive_datetime(run.started_at) %></td>
                      <td class="mono muted"><%= format_archive_datetime(run.finished_at) %></td>
                      <td class="numeric"><%= format_duration_ms(run.duration_ms) %></td>
                      <td>
                        <div class="detail-stack">
                          <span class="mono archive-model"><%= run.model || "unknown" %></span>
                          <span class={provider_badge_class(run.provider)}><%= run.provider || "unknown" %></span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span><%= format_int(get_in(run, [:tokens, :total_tokens])) %></span>
                          <span class="muted"><%= format_cost(run.cost) %></span>
                        </div>
                      </td>
                      <td>
                        <div class="archive-links">
                          <a :if={run.linear_url} class="issue-link" href={run.linear_url} onclick="event.stopPropagation()">Linear</a>
                          <a :if={run.pr_url} class="issue-link" href={run.pr_url} onclick="event.stopPropagation()">PR</a>
                          <a class="issue-link" href={"/api/v1/#{run.issue_identifier}"} onclick="event.stopPropagation()">JSON</a>
                        </div>
                      </td>
                      <td>
                        <span class="event-text" title={run.last_meaningful_result || "n/a"}><%= run.last_meaningful_result || "n/a" %></span>
                      </td>
                      <td>
                        <span class="archive-activity" title={archive_activity_title(run)}>
                          <span class="archive-activity-fill" style={archive_activity_style(run)}></span>
                        </span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <div class="archive-pagination">
                <button type="button" class="subtle-button" phx-click="page_archived" phx-value-page={archived_view.page - 1} disabled={archived_view.page <= 1}>Previous</button>
                <span class="muted event-meta">Page <%= archived_view.page %> of <%= archived_view.page_count %> · <%= archived_view.total %> runs</span>
                <button type="button" class="subtle-button" phx-click="page_archived" phx-value-page={archived_view.page + 1} disabled={archived_view.page >= archived_view.page_count}>Next</button>
              </div>
            <% end %>
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
              <div class="detail-stack">
                <span class={state_badge_class(tracker_state(@selected_issue_data) || "n/a")}><%= tracker_state(@selected_issue_data) || "n/a" %></span>
                <%= if paused_state_summary(@selected_issue_data) do %>
                  <span class="muted" style="font-size: 11px;"><%= paused_state_summary(@selected_issue_data) %></span>
                <% end %>
              </div>
            </div>
            <div class="panel-metric">
              <span class="panel-metric-label"><%= selected_time_label(@selected_issue_data) %></span>
              <span class="numeric"><%= selected_time_value(@selected_issue_data, @now) %></span>
            </div>
            <div class="panel-metric">
              <span class="panel-metric-label">Tokens</span>
              <span class="numeric"><%= format_int(selected_total_tokens(@selected_issue_data)) %></span>
            </div>
            <div class="panel-metric">
              <%= if @selected_issue_data[:exit_reason] do %>
                <span class="panel-metric-label">Result</span>
                <div class="detail-stack">
                  <span class={exit_reason_class(@selected_issue_data[:exit_reason])}><%= @selected_issue_data[:exit_reason] %></span>
                  <%= if @selected_issue_data[:exit_reason] == "handed_off" && @selected_issue_data[:non_active_state] do %>
                    <span class="muted" style="font-size: 11px;">issue &rarr; <%= @selected_issue_data[:non_active_state] %></span>
                  <% end %>
                </div>
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

          <%= if model_routing_section(@selected_issue_data, @selected_runs) do %>
            <div class="section-card" style="margin-bottom: 16px; padding: 16px;">
              <p class="panel-metric-label">Model routing</p>
              <%= render_model_routing(@selected_issue_data, @selected_runs) %>
            </div>
          <% end %>

          <%= if @selected_run_projection do %>
            <div class="section-card" style="margin-bottom: 16px; padding: 16px;">
              <p class="panel-metric-label">Ledger browser</p>
              <p class="muted" style="font-size: 12px; margin-bottom: 12px;">
                Manifest/checkpoint timeline for the selected run.
              </p>

              <div class="panel-metrics" style="margin-bottom: 12px;">
                <div class="panel-metric">
                  <span class="panel-metric-label">Run</span>
                  <span class="mono" style="font-size: 11px;"><%= @selected_run_projection.run_id || "n/a" %></span>
                </div>
                <div class="panel-metric">
                  <span class="panel-metric-label">Session</span>
                  <span class="mono" style="font-size: 11px;"><%= @selected_run_projection.session_id || "n/a" %></span>
                </div>
                <div class="panel-metric">
                  <span class="panel-metric-label">Status</span>
                  <span class={state_badge_class(@selected_run_projection.status || @selected_run_projection.exit_reason || "n/a")}><%= @selected_run_projection.status || @selected_run_projection.exit_reason || "n/a" %></span>
                </div>
                <div class="panel-metric">
                  <span class="panel-metric-label">Steps</span>
                  <span class="numeric"><%= length(@selected_run_projection.timeline || []) %></span>
                </div>
              </div>

              <div class="event-stream" style="max-height: 320px;">
                <div :for={step <- Enum.reverse(@selected_run_projection.timeline || [])} class="event-row">
                  <span class={ledger_step_class(step)}>
                    <%= step.kind %>
                  </span>
                  <span class="event-row-message">
                    <%= step.summary || step.outcome || step.kind %>
                  </span>
                  <span class="muted event-row-message" style="margin-left: auto; text-align: right;">
                    <%= ledger_step_meta(step) %>
                  </span>
                </div>
              </div>
            </div>
          <% end %>

          <%= if entry_has_links?(@selected_issue_data) do %>
            <div class="section-card" style="margin-bottom: 16px; padding: 16px;">
              <p class="panel-metric-label">Links</p>
              <%= render_entry_links(%{entry: @selected_issue_data, compact: false}) %>
            </div>
          <% end %>

          <%= if @selected_issue_data[:interrupt] do %>
            <div class="section-card" style="margin-bottom: 16px; padding: 16px;">
              <p class="panel-metric-label">Guidance</p>
              <p class="muted" style="font-size: 12px; margin-bottom: 12px;">
                <%= get_in(@selected_issue_data, [:interrupt, :question]) || get_in(@selected_issue_data, [:interrupt, :recommendation]) || "Provide operator guidance to resume this paused run." %>
              </p>
              <%= if final_report_interrupt_summary(@selected_issue_data) do %>
                <p class="muted" style="font-size: 12px; margin-bottom: 12px;">
                  <%= final_report_interrupt_summary(@selected_issue_data) %>
                </p>
              <% end %>
              <%= if paused_claim_status(@selected_issue_data) do %>
                <p class="muted" style="font-size: 12px; margin-bottom: 12px;">
                  <%= paused_claim_status(@selected_issue_data) %>
                </p>
              <% end %>
              <form phx-submit="submit_guidance">
                <input type="hidden" name="issue-id" value={@selected_issue_data[:issue_id]} />
                <textarea
                  name="guidance"
                  rows="4"
                  placeholder="Tell the agent how to unblock this run..."
                  style="width: 100%; resize: vertical; border-radius: 12px; border: 1px solid var(--border); background: var(--surface); color: var(--text); padding: 10px;"
                ></textarea>
                <div style="margin-top: 10px; display: flex; gap: 8px; flex-wrap: wrap;">
                  <button type="submit" class="subtle-button">Resume with guidance</button>
                  <%= for response <- guidance_responses(@selected_issue_data) do %>
                    <button
                      type="button"
                      class="subtle-button"
                      phx-click="submit_guidance"
                      phx-value-issue-id={@selected_issue_data[:issue_id]}
                      phx-value-guidance={response.guidance || response.id}
                    >
                      <%= response.label || response.id %>
                    </button>
                  <% end %>
                </div>
              </form>
            </div>
          <% end %>

          <% filtered_events = filtered_selected_event_log(@selected_issue_data, @event_filters) %>
          <% selected_event = selected_event_entry(filtered_events, @selected_event_index) %>
          <% max_hist_tokens = Enum.reduce(filtered_events, 0, fn entry, acc -> max(acc, selected_event_total_tokens(entry)) end) %>

          <div class="panel-stream-header">
            <span class="panel-metric-label">Event stream</span>
            <span class="muted" style="font-size: 11px;"><%= length(filtered_events) %> events</span>
          </div>

          <form class="event-toolbar" phx-change="filter_events">
            <label class="logs-control">
              <span class="logs-control-label">Search</span>
              <input
                type="search"
                name="query"
                value={@event_filters.query}
                placeholder="Search event text"
                class="logs-search-input"
                phx-debounce="250"
              />
            </label>

            <label class="logs-control">
              <span class="logs-control-label">Role</span>
              <select name="role" class="logs-select">
                <option value="all" selected={@event_filters.role == "all"}>All roles</option>
                <option value="assistant" selected={@event_filters.role == "assistant"}>Assistant</option>
                <option value="user" selected={@event_filters.role == "user"}>User</option>
                <option value="system" selected={@event_filters.role == "system"}>System</option>
                <option value="tool" selected={@event_filters.role == "tool"}>Tool</option>
                <option value="read" selected={@event_filters.role == "read"}>Read</option>
                <option value="write" selected={@event_filters.role == "write"}>Write</option>
                <option value="edit" selected={@event_filters.role == "edit"}>Edit</option>
                <option value="grep" selected={@event_filters.role == "grep"}>Grep</option>
                <option value="bash" selected={@event_filters.role == "bash"}>Bash</option>
                <option value="linear" selected={@event_filters.role == "linear"}>Linear</option>
                <option value="github" selected={@event_filters.role == "github"}>GitHub</option>
              </select>
            </label>

            <div class="event-view-toggle">
              <span class="logs-control-label">View</span>
              <button type="button" class="subtle-button" phx-click="toggle_event_mode"><%= if @selected_event_mode == :raw, do: "Pretty", else: "Raw" %></button>
            </div>
          </form>

          <%= if filtered_events == [] do %>
            <p class="empty-state">Waiting for agent activity...</p>
          <% else %>
            <div class="event-token-histogram" aria-hidden="true">
              <%= for {entry, idx} <- Enum.with_index(filtered_events) do %>
                <button
                  type="button"
                  class={"event-token-bar #{if idx == @selected_event_index, do: "event-token-bar-selected", else: ""}"}
                  phx-click="select_event"
                  phx-value-index={idx}
                  title={"#{to_string(entry.event)} · #{selected_event_total_tokens(entry)} tokens"}
                  style={"height: #{event_histogram_height(entry, max_hist_tokens)}px"}
                ></button>
              <% end %>
            </div>

            <%= if selected_event do %>
              <div class="event-detail-card">
                <div class="event-detail-header">
                  <div>
                    <p class="panel-metric-label"><%= selected_event.event %></p>
                    <p class="muted" style="font-size: 12px;"><%= selected_event.at %></p>
                  </div>
                  <div class="event-detail-actions">
                    <button type="button" class="subtle-button" phx-click="toggle_event_mode"><%= if @selected_event_mode == :raw, do: "Pretty", else: "Raw" %></button>
                    <button
                      type="button"
                      class="subtle-button"
                      data-label="Copy"
                      data-copy={selected_event_raw_text(selected_event)}
                      onclick="event.stopPropagation(); navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                    >
                      Copy
                    </button>
                  </div>
                </div>
                <div class="event-detail-body">
                  <div class="event-detail-metadata">
                    <span class={event_type_class(selected_event.event)}><%= selected_event.event %></span>
                    <span class="muted">Tokens <%= selected_event_total_tokens(selected_event) %></span>
                    <%= if selected_event_token_cost(selected_event) do %>
                      <span class="muted">Cost <%= format_cost(selected_event_token_cost(selected_event)) %></span>
                    <% end %>
                  </div>
                  <%= if @selected_event_mode == :raw do %>
                    <pre class="code-panel"><%= selected_event_raw_text(selected_event) %></pre>
                  <% else %>
                    <div class="event-detail-message"><%= render_event_message(selected_event.message) %></div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <div class="event-stream" id="event-stream" phx-hook="ScrollBottom">
              <div :for={{entry, idx} <- Enum.with_index(filtered_events)} class={"event-row #{if idx == @selected_event_index, do: "event-row-selected", else: ""}"} phx-click="select_event" phx-value-index={idx}>
                <span class={event_type_class(entry.event)}>
                  <%= if tool_event?(entry.event) do %><svg class="event-icon" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/></svg><% end %><%= entry.event %>
                </span>
                <span class="event-row-message"><%= render_event_message(entry.message) %></span>
                <span class="event-row-tokens numeric"><%= selected_event_total_tokens(entry) %></span>
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

  defp archived_table_view(payload, filters) do
    payload
    |> Map.get(:archived_table, [])
    |> ArchivedRuns.view(filters)
  end

  defp sort_indicator(%{sort_by: field, sort_dir: "asc"}, field), do: "↑"
  defp sort_indicator(%{sort_by: field, sort_dir: "desc"}, field), do: "↓"
  defp sort_indicator(_filters, _field), do: ""

  defp archived_row_class(run, selected_issue, selected_issue_data) do
    selected? =
      (selected_issue == run.issue_identifier and selected_issue_data) &&
        selected_issue_data[:filename] == run.filename

    status_class = if run.status in ["failed", "exited", "error"], do: " archive-row-attention", else: ""
    selected_class = if selected?, do: " data-table-row-selected", else: ""
    "data-table-row#{selected_class}#{status_class}"
  end

  defp format_archive_datetime(nil), do: "n/a"

  defp format_archive_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> iso_string
    end
  end

  defp format_archive_datetime(_value), do: "n/a"

  defp format_duration_ms(ms) when is_integer(ms) and ms >= 0 do
    seconds = div(ms, 1_000)
    hours = div(seconds, 3_600)
    minutes = seconds |> rem(3_600) |> div(60)
    remaining_seconds = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{remaining_seconds}s"
      true -> "#{remaining_seconds}s"
    end
  end

  defp format_duration_ms(_ms), do: "n/a"

  defp format_cost(cost) when is_number(cost) and cost > 0, do: "$#{:erlang.float_to_binary(cost / 1.0, decimals: 4)}"
  defp format_cost(_cost), do: "cost n/a"

  defp archive_activity_style(run) do
    total_tokens = get_in(run, [:tokens, :total_tokens]) || 0
    width = total_tokens |> :math.log10() |> Kernel.*(20) |> round() |> min(100) |> max(8)
    "width: #{width}%"
  rescue
    _ -> "width: 8%"
  end

  defp archive_activity_title(run) do
    ["tokens=#{format_int(get_in(run, [:tokens, :total_tokens]))}", "duration=#{format_duration_ms(run.duration_ms)}", "status=#{run.status}"]
    |> Enum.join(" · ")
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

  @spec selected_run_projection_for_test(map(), map() | nil) :: map() | nil
  def selected_run_projection_for_test(payload, run), do: selected_run_projection_for(payload, run)

  @spec ledger_step_class_for_test(map() | nil) :: String.t()
  def ledger_step_class_for_test(step), do: ledger_step_class(step)

  @spec ledger_step_meta_for_test(map() | nil) :: String.t()
  def ledger_step_meta_for_test(step), do: ledger_step_meta(step)

  defp selected_run_projection_for(_payload, nil), do: nil

  defp selected_run_projection_for(payload, run) when is_map(payload) and is_map(run) do
    projections = Map.get(payload, :run_timelines, Map.get(payload, "run_timelines", [])) || []

    identifier = entry_value(run, :identifier) || entry_value(run, :issue_identifier)
    run_id = entry_value(run, :run_id)
    session_id = entry_value(run, :session_id)
    started_at = entry_value(run, :started_at)

    {score, projection} =
      Enum.reduce(projections, {0, nil}, fn candidate, {best_score, best_projection} ->
        candidate_score =
          run_projection_match_score(candidate, identifier, run_id, session_id, started_at)

        if candidate_score > best_score do
          {candidate_score, candidate}
        else
          {best_score, best_projection}
        end
      end)

    if score > 0, do: projection, else: nil
  end

  defp selected_run_projection_for(_payload, _run), do: nil

  defp entry_value(entry, key) when is_map(entry) and is_atom(key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp entry_value(_entry, _key), do: nil

  defp run_projection_match_score(projection, identifier, run_id, session_id, started_at) do
    proj_identifier = entry_value(projection, :identifier)
    proj_run_id = entry_value(projection, :run_id)
    proj_session_id = entry_value(projection, :session_id)
    proj_started_at = entry_value(projection, :started_at)

    cond do
      run_id_match?(proj_run_id, run_id) -> 4
      session_match?(proj_identifier, identifier, proj_session_id, session_id) -> 3
      started_match?(proj_identifier, identifier, proj_started_at, started_at) -> 2
      proj_identifier == identifier -> 1
      true -> 0
    end
  end

  defp run_id_match?(proj_run_id, run_id), do: is_binary(run_id) and proj_run_id == run_id

  defp session_match?(proj_identifier, identifier, proj_session_id, session_id) do
    is_binary(session_id) and is_binary(proj_session_id) and proj_identifier == identifier and
      proj_session_id == session_id
  end

  defp started_match?(proj_identifier, identifier, proj_started_at, started_at) do
    is_binary(started_at) and is_binary(proj_started_at) and proj_identifier == identifier and
      proj_started_at == started_at
  end

  defp ledger_step_class(step) do
    status = entry_value(step, :status) || entry_value(step, :kind) || "n/a"
    state_badge_class(status)
  end

  defp ledger_step_meta(step) do
    [ledger_source_label(step), ledger_artifact_summary(step)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp ledger_source_label(step) do
    step
    |> entry_value(:source)
    |> source_label()
  end

  defp source_label(source) when is_map(source) do
    case entry_value(source, :kind) do
      "checkpoint" -> checkpoint_source_label(source)
      "event_log" -> event_log_source_label(source)
      "manifest" -> "manifest"
      kind when is_binary(kind) -> kind
      _ -> nil
    end
  end

  defp source_label(_source), do: nil

  defp checkpoint_source_label(source) do
    ["checkpoint", entry_value(source, :path)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
  end

  defp event_log_source_label(source) do
    index = entry_value(source, :event_index)
    if is_integer(index), do: "event log ##{index + 1}", else: "event log"
  end

  defp ledger_artifact_summary(step) do
    case entry_value(step, :artifacts) do
      artifacts when is_list(artifacts) and artifacts != [] ->
        artifacts
        |> Enum.map(&artifact_summary/1)
        |> Enum.uniq()
        |> Enum.join(" · ")

      _ ->
        nil
    end
  end

  defp artifact_summary(artifact) when is_map(artifact) do
    kind = entry_value(artifact, :kind) || "artifact"
    path = entry_value(artifact, :path)

    if is_binary(path), do: "#{kind}: #{path}", else: to_string(kind)
  end

  defp artifact_summary(artifact), do: to_string(artifact)

  defp find_issue_entry(payload, identifier) do
    [:needs_guidance, :paused, :running, :retrying]
    |> Enum.flat_map(&Map.get(payload, &1, []))
    |> Enum.find(&(&1.issue_identifier == identifier))
  end

  defp default_log_filters do
    %{query: "", status: "all", window: "all", sort_by: "date", sort_dir: "desc"}
  end

  defp default_event_filters do
    %{query: "", role: "all"}
  end

  defp merge_log_filters(filters, params) do
    %{
      query: normalize_filter_text(Map.get(params, "query", Map.get(filters, :query, ""))),
      status: normalize_filter_choice(Map.get(params, "status", Map.get(filters, :status, "all")), "all"),
      window: normalize_filter_choice(Map.get(params, "window", Map.get(filters, :window, "all")), "all"),
      sort_by: Map.get(filters, :sort_by, "date"),
      sort_dir: Map.get(filters, :sort_dir, "desc")
    }
  end

  defp merge_event_filters(filters, params) do
    %{
      query: normalize_filter_text(Map.get(params, "query", Map.get(filters, :query, ""))),
      role: normalize_filter_choice(Map.get(params, "role", Map.get(filters, :role, "all")), "all")
    }
  end

  defp normalize_filter_text(nil), do: ""
  defp normalize_filter_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_filter_text(value), do: to_string(value)

  defp normalize_filter_choice(nil, default), do: default
  defp normalize_filter_choice("", default), do: default
  defp normalize_filter_choice(value, _default) when is_binary(value), do: String.trim(value)
  defp normalize_filter_choice(value, _default), do: to_string(value)

  defp toggle_sort_direction("asc"), do: "desc"
  defp toggle_sort_direction(_), do: "asc"

  defp dashboard_log_rows(payload, filters, now \\ DateTime.utc_now()) do
    payload
    |> build_dashboard_log_rows(now)
    |> filter_dashboard_log_rows(filters, now)
    |> sort_dashboard_log_rows(filters)
  end

  defp build_dashboard_log_rows(payload, now) do
    []
    |> Kernel.++(Enum.map(Map.get(payload, :running, []), &running_dashboard_log_row(&1, now)))
    |> Kernel.++(Enum.map(Map.get(payload, :paused, []), &paused_dashboard_log_row(&1, now)))
    |> Kernel.++(Enum.map(Map.get(payload, :retrying, []), &retrying_dashboard_log_row(&1, now)))
    |> Kernel.++(Enum.map(Map.get(payload, :archived, []), &archived_dashboard_log_row(&1, now)))
  end

  defp filter_dashboard_log_rows(rows, filters, now) do
    query = filters[:query] || ""
    status = filters[:status] || "all"
    window = filters[:window] || "all"

    Enum.filter(rows, fn row ->
      dashboard_log_status_matches?(row, status) and
        dashboard_log_window_matches?(row, window, now) and
        dashboard_log_query_matches?(row, query)
    end)
  end

  defp sort_dashboard_log_rows(rows, filters) do
    sort_by = filters[:sort_by] || "date"
    direction = if (filters[:sort_dir] || "desc") == "asc", do: :asc, else: :desc

    Enum.sort_by(rows, &dashboard_log_sort_value(&1, sort_by), direction)
  end

  defp dashboard_log_sort_value(row, "date"), do: dashboard_timestamp_to_unix(Map.get(row, :sort_at))
  defp dashboard_log_sort_value(row, "model"), do: sort_string(Map.get(row, :model))
  defp dashboard_log_sort_value(row, "provider"), do: sort_string(Map.get(row, :provider))
  defp dashboard_log_sort_value(row, "app"), do: sort_string(Map.get(row, :app))
  defp dashboard_log_sort_value(row, "input_tokens"), do: Map.get(row, :input_tokens, 0)
  defp dashboard_log_sort_value(row, "output_tokens"), do: Map.get(row, :output_tokens, 0)
  defp dashboard_log_sort_value(row, "cost"), do: Map.get(row, :cost) || 0.0
  defp dashboard_log_sort_value(row, "speed"), do: Map.get(row, :speed) || 0.0
  defp dashboard_log_sort_value(row, "finish"), do: sort_string(Map.get(row, :finish_reason))
  defp dashboard_log_sort_value(row, _), do: dashboard_timestamp_to_unix(Map.get(row, :sort_at))

  defp sort_string(nil), do: ""
  defp sort_string(value) when is_binary(value), do: String.downcase(value)
  defp sort_string(value), do: String.downcase(to_string(value))

  defp dashboard_timestamp_to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)

  defp dashboard_timestamp_to_unix(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp dashboard_timestamp_to_unix(_), do: 0

  defp dashboard_log_status_matches?(_row, "all"), do: true
  defp dashboard_log_status_matches?(row, "active"), do: row.kind in [:running, :paused, :retrying]
  defp dashboard_log_status_matches?(row, status), do: Atom.to_string(row.kind) == status

  defp dashboard_log_window_matches?(_row, "all", _now), do: true

  defp dashboard_log_window_matches?(row, window, now) do
    case {dashboard_timestamp_to_unix(Map.get(row, :sort_at)), dashboard_window_seconds(window)} do
      {0, _} ->
        true

      {_row_unix, :infinity} ->
        true

      {row_unix, window_seconds} ->
        age_seconds = DateTime.to_unix(now) - row_unix
        age_seconds <= window_seconds
    end
  end

  defp dashboard_window_seconds("24h"), do: 24 * 60 * 60
  defp dashboard_window_seconds("7d"), do: 7 * 24 * 60 * 60
  defp dashboard_window_seconds("30d"), do: 30 * 24 * 60 * 60
  defp dashboard_window_seconds(_), do: :infinity

  defp dashboard_log_query_matches?(_row, ""), do: true

  defp dashboard_log_query_matches?(row, query) when is_binary(query) do
    haystack =
      [
        row.identifier,
        row.model,
        row.provider,
        row.app,
        row.finish_reason,
        row.message,
        row.status_label,
        row.session_id
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &String.downcase(to_string(&1)))

    String.contains?(haystack, String.downcase(String.trim(query)))
  end

  defp dashboard_log_query_matches?(_row, _query), do: true

  defp running_dashboard_log_row(entry, now) do
    runtime_seconds = runtime_seconds_from_started_at(entry.started_at, now)
    total_tokens = get_in(entry, [:tokens, :total_tokens]) || 0

    %{
      kind: :running,
      status_label: "Running",
      identifier: entry.issue_identifier,
      issue_id: entry.issue_id,
      sort_at: dashboard_timestamp(entry.started_at),
      model: Map.get(entry, :model) || Map.get(entry, :adapter) || "n/a",
      provider: Map.get(entry, :provider),
      app: Map.get(entry, :adapter),
      input_tokens: get_in(entry, [:tokens, :input_tokens]) || 0,
      output_tokens: get_in(entry, [:tokens, :output_tokens]) || 0,
      total_tokens: total_tokens,
      cost: Map.get(entry, :cost),
      runtime_seconds: runtime_seconds,
      speed: dashboard_speed(total_tokens, runtime_seconds),
      finish_reason: Map.get(entry, :last_event) || Map.get(entry, :state),
      message: Map.get(entry, :last_message),
      session_id: Map.get(entry, :session_id),
      source_link: "/api/v1/#{entry.issue_identifier}"
    }
  end

  defp paused_dashboard_log_row(entry, now) do
    runtime_seconds = runtime_seconds_from_started_at(dashboard_row_timestamp(entry, :paused_at), now)
    total_tokens = dashboard_row_total_tokens(entry)

    %{
      kind: :paused,
      status_label: "Paused",
      identifier: entry.issue_identifier,
      issue_id: entry.issue_id,
      sort_at: dashboard_timestamp(dashboard_row_timestamp(entry, :paused_at)),
      model: dashboard_row_model(entry),
      provider: Map.get(entry, :provider),
      app: dashboard_row_app(entry),
      input_tokens: dashboard_row_input_tokens(entry),
      output_tokens: dashboard_row_output_tokens(entry),
      total_tokens: total_tokens,
      cost: Map.get(entry, :cost),
      runtime_seconds: runtime_seconds,
      speed: dashboard_speed(total_tokens, runtime_seconds),
      finish_reason: dashboard_paused_finish_reason(entry),
      message: guidance_waiting_label(entry),
      session_id: Map.get(entry, :session_id),
      source_link: dashboard_row_source_link(entry.issue_identifier)
    }
  end

  defp retrying_dashboard_log_row(entry, _now) do
    %{
      kind: :retrying,
      status_label: "Retrying",
      identifier: entry.issue_identifier,
      issue_id: entry.issue_id,
      sort_at: dashboard_timestamp(entry.due_at),
      model: "n/a",
      provider: nil,
      app: nil,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cost: nil,
      runtime_seconds: nil,
      speed: nil,
      finish_reason: entry.error || "retrying",
      message: entry.error,
      session_id: nil,
      source_link: "/api/v1/#{entry.issue_identifier}"
    }
  end

  defp archived_dashboard_log_row(group, _now) do
    latest_run = dashboard_latest_run(group.runs)
    runtime_seconds = dashboard_duration_seconds(latest_run.started_at, latest_run.finished_at)
    total_tokens = dashboard_group_total_tokens(group)

    %{
      kind: :archived,
      status_label: "Archived",
      identifier: group.issue_identifier,
      issue_id: Map.get(latest_run, :issue_id) || group.issue_identifier,
      sort_at: dashboard_timestamp(dashboard_row_timestamp(group, latest_run, :latest_finished_at, :finished_at)),
      model: dashboard_row_model(latest_run),
      provider: latest_run.provider,
      app: dashboard_row_app(latest_run),
      input_tokens: dashboard_row_input_tokens(latest_run),
      output_tokens: dashboard_row_output_tokens(latest_run),
      total_tokens: total_tokens,
      cost: latest_run.cost,
      runtime_seconds: runtime_seconds,
      speed: dashboard_speed(total_tokens, runtime_seconds),
      finish_reason: group.latest_result,
      message: dashboard_archived_message(group),
      session_id: latest_run.session_id,
      source_link: dashboard_row_source_link(group.issue_identifier)
    }
  end

  defp dashboard_row_timestamp(entry, key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp dashboard_row_timestamp(group, latest_run, primary_key, fallback_key) do
    Map.get(group, primary_key) ||
      Map.get(group, Atom.to_string(primary_key)) ||
      Map.get(latest_run, fallback_key) ||
      Map.get(latest_run, Atom.to_string(fallback_key))
  end

  defp dashboard_row_total_tokens(entry) do
    get_in(entry, [:tokens, :total_tokens]) || 0
  end

  defp dashboard_paused_finish_reason(entry) do
    Map.get(entry, :blocked_dispatch_reason) ||
      get_in(entry, [:interrupt, :reason]) ||
      Map.get(entry, :state) ||
      "paused"
  end

  defp dashboard_latest_run(runs) when is_list(runs), do: List.last(runs) || %{}
  defp dashboard_latest_run(_runs), do: %{}

  defp dashboard_group_total_tokens(group) do
    Map.get(group, :total_tokens) || Map.get(group, "total_tokens") || 0
  end

  defp dashboard_row_model(entry), do: dashboard_log_model(entry)
  defp dashboard_row_app(entry), do: dashboard_log_app(entry)
  defp dashboard_row_input_tokens(entry), do: dashboard_log_input_tokens(entry)
  defp dashboard_row_output_tokens(entry), do: dashboard_log_output_tokens(entry)

  defp dashboard_archived_message(group) do
    "#{Map.get(group, :run_count, 0)} run#{if Map.get(group, :run_count, 0) == 1, do: "", else: "s"}"
  end

  defp dashboard_row_source_link(identifier) when is_binary(identifier), do: "/api/v1/#{identifier}"
  defp dashboard_row_source_link(_identifier), do: "/api/v1/n-a"

  defp dashboard_log_selected?(selected_issue, row), do: selected_issue == row.identifier

  defp dashboard_log_message(%{message: message}) when is_binary(message), do: message
  defp dashboard_log_message(_), do: "n/a"

  defp dashboard_log_kind_label(%{kind: :running}), do: "Running"
  defp dashboard_log_kind_label(%{kind: :paused}), do: "Paused"
  defp dashboard_log_kind_label(%{kind: :retrying}), do: "Retrying"
  defp dashboard_log_kind_label(%{kind: :archived}), do: "Archived"
  defp dashboard_log_kind_label(_), do: "Unknown"

  defp dashboard_log_status_class(%{kind: :running}), do: "state-badge state-badge-active"
  defp dashboard_log_status_class(%{kind: :paused}), do: "state-badge state-badge-warning"
  defp dashboard_log_status_class(%{kind: :retrying}), do: "state-badge state-badge-warning"
  defp dashboard_log_status_class(%{kind: :archived}), do: "state-badge"
  defp dashboard_log_status_class(_), do: "state-badge"

  defp dashboard_log_finish_class(%{kind: :running}), do: "state-badge state-badge-active"
  defp dashboard_log_finish_class(%{kind: :paused}), do: "state-badge state-badge-warning"
  defp dashboard_log_finish_class(%{kind: :retrying}), do: "state-badge state-badge-warning"
  defp dashboard_log_finish_class(%{kind: :archived, finish_reason: "completed"}), do: "state-badge state-badge-active"
  defp dashboard_log_finish_class(%{kind: :archived, finish_reason: "handed_off"}), do: "state-badge state-badge-handoff"
  defp dashboard_log_finish_class(%{kind: :archived}), do: "state-badge state-badge-danger"
  defp dashboard_log_finish_class(_), do: "state-badge"

  defp dashboard_log_date(%{sort_at: %DateTime{} = dt}) do
    Calendar.strftime(dt, "%b %-d, %I:%M %p")
  end

  defp dashboard_log_date(%{sort_at: value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%b %-d, %I:%M %p")
      _ -> value
    end
  end

  defp dashboard_log_date(_), do: "n/a"

  defp dashboard_log_model(row), do: Map.get(row, :model) || Map.get(row, :app) || "n/a"
  defp dashboard_log_provider(row), do: Map.get(row, :provider)
  defp dashboard_log_app(row), do: Map.get(row, :app)
  defp dashboard_log_input_tokens(row), do: Map.get(row, :input_tokens) || 0
  defp dashboard_log_output_tokens(row), do: Map.get(row, :output_tokens) || 0
  defp dashboard_log_cost(row), do: Map.get(row, :cost)
  defp dashboard_log_speed(row), do: Map.get(row, :speed)
  defp dashboard_log_finish(row), do: Map.get(row, :finish_reason)
  defp dashboard_log_source_link(row), do: Map.get(row, :source_link) || "/api/v1/#{row.identifier}"

  defp dashboard_speed(_tokens, nil), do: nil
  defp dashboard_speed(_tokens, 0), do: nil

  defp dashboard_speed(tokens, runtime_seconds) when is_number(tokens) and is_number(runtime_seconds) do
    Float.round(tokens / runtime_seconds, 1)
  end

  defp dashboard_speed(_tokens, _runtime_seconds), do: nil

  defp dashboard_duration_seconds(nil, nil), do: nil

  defp dashboard_duration_seconds(started_at, finished_at) do
    with %DateTime{} = s <- dashboard_timestamp(started_at),
         %DateTime{} = f <- dashboard_timestamp(finished_at) do
      DateTime.diff(f, s, :second)
    else
      _ -> nil
    end
  end

  defp dashboard_timestamp(%DateTime{} = dt), do: dt

  defp dashboard_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp dashboard_timestamp(_), do: nil

  defp filtered_selected_event_log(selected_issue_data, filters) do
    selected_event_log(selected_issue_data)
    |> Enum.filter(&dashboard_event_matches?(&1, filters))
  end

  defp dashboard_event_matches?(entry, filters) do
    query = filters[:query] || ""
    role = filters[:role] || "all"

    role_match? = role == "all" or to_string(entry.event) == role

    query_match? =
      if query == "" do
        true
      else
        haystack =
          [entry.event, entry.message]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join(" ", &String.downcase(to_string(&1)))

        String.contains?(haystack, String.downcase(query))
      end

    role_match? and query_match?
  end

  defp selected_event_entry(events, index) when is_list(events) do
    Enum.at(events, index) || List.first(events)
  end

  defp selected_event_tokens(%{tokens: tokens}) when is_map(tokens), do: tokens
  defp selected_event_tokens(_), do: %{}

  defp selected_event_total_tokens(entry) do
    tokens = selected_event_tokens(entry)
    Map.get(tokens, :total_tokens) || Map.get(tokens, "total_tokens") || 0
  end

  defp selected_event_token_cost(entry) do
    tokens = selected_event_tokens(entry)
    Map.get(tokens, :cost) || Map.get(tokens, "cost")
  end

  defp selected_event_raw_text(%{message: message}) when is_binary(message), do: message
  defp selected_event_raw_text(_), do: ""

  defp event_histogram_height(_entry, 0), do: 8

  defp event_histogram_height(entry, max_tokens) do
    tokens = selected_event_total_tokens(entry)
    ratio = if max_tokens > 0, do: tokens / max_tokens, else: 0
    max(trunc(ratio * 100), if(tokens > 0, do: 8, else: 2))
  end

  defp format_cost(nil), do: "n/a"
  defp format_cost(cost) when is_float(cost), do: "$#{Float.round(cost, 3)}"
  defp format_cost(cost) when is_integer(cost), do: "$#{cost}"
  defp format_cost(_), do: "n/a"

  defp format_speed(nil), do: "n/a"
  defp format_speed(speed) when is_number(speed), do: "#{Float.round(speed, 1)} tok/s"
  defp format_speed(_), do: "n/a"

  defp provider_label(nil), do: "n/a"
  defp provider_label("openrouter"), do: "OpenRouter"
  defp provider_label("codex"), do: "Codex"
  defp provider_label("pi"), do: "Pi"
  defp provider_label("claude_code"), do: "Claude Code"
  defp provider_label("openai"), do: "OpenAI"

  defp provider_label(provider) when is_binary(provider) do
    provider
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp log_row_selected?(selected_issue, row), do: dashboard_log_selected?(selected_issue, row)
  defp log_row_kind_label(row), do: dashboard_log_kind_label(row)
  defp log_row_status_class(row), do: dashboard_log_status_class(row)
  defp log_row_date(row), do: dashboard_log_date(row)
  defp log_row_model(row), do: dashboard_log_model(row)
  defp log_row_provider(row), do: dashboard_log_provider(row)
  defp log_row_app(row), do: dashboard_log_app(row)
  defp log_row_input_tokens(row), do: dashboard_log_input_tokens(row)
  defp log_row_output_tokens(row), do: dashboard_log_output_tokens(row)
  defp log_row_cost(row), do: dashboard_log_cost(row)
  defp log_row_speed(row), do: dashboard_log_speed(row)
  defp log_row_finish(row), do: dashboard_log_finish(row)
  defp log_row_message(row), do: dashboard_log_message(row)
  defp log_row_source_link(row), do: dashboard_log_source_link(row)
  defp log_row_finish_class(row), do: dashboard_log_finish_class(row)

  defp sort_indicator(filters, field) do
    if filters[:sort_by] == field do
      if filters[:sort_dir] == "asc", do: "▲", else: "▼"
    else
      ""
    end
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

  defp selected_time_label(selected_issue_data) do
    cond do
      selected_issue_data[:finished_at] -> "Duration"
      selected_issue_data[:paused_at] -> "Paused"
      selected_issue_data[:started_at] -> "Runtime"
      true -> "Time"
    end
  end

  defp selected_time_value(selected_issue_data, now) do
    cond do
      selected_issue_data[:finished_at] ->
        format_duration(selected_issue_data[:started_at], selected_issue_data[:finished_at])

      selected_issue_data[:paused_at] ->
        selected_issue_data[:paused_at]

      selected_issue_data[:started_at] ->
        format_runtime_and_turns(selected_issue_data[:started_at], selected_issue_data[:turn_count], now)

      true ->
        "n/a"
    end
  end

  defp selected_total_tokens(selected_issue_data) do
    get_in(selected_issue_data, [:tokens, :total_tokens])
  end

  defp selected_event_log(selected_issue_data) do
    Map.get(selected_issue_data, :event_log, []) || []
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

  defp quick_guidance_response(entry) do
    entry
    |> guidance_responses()
    |> Enum.find(fn response -> Map.get(response, :quick) == true end)
  end

  defp guidance_responses(%{paused: paused}) when is_map(paused), do: guidance_responses(paused)
  defp guidance_responses(entry) when is_map(entry), do: Map.get(entry, :suggested_responses, []) || []
  defp guidance_responses(_entry), do: []

  defp guidance_waiting_label(entry) do
    blocked_side_effect = Map.get(entry, :blocked_side_effect) || get_in(entry, [:interrupt, :blocked_side_effect]) || %{}

    Map.get(blocked_side_effect, :label) ||
      entry
      |> get_in([:interrupt, :reason])
      |> humanize_interrupt_reason()
  end

  defp guidance_waiting_meta(entry) do
    blocked_side_effect = Map.get(entry, :blocked_side_effect) || get_in(entry, [:interrupt, :blocked_side_effect]) || %{}

    Map.get(blocked_side_effect, :action) ||
      get_in(entry, [:interrupt, :question]) ||
      get_in(entry, [:interrupt, :recommendation]) ||
      "operator guidance"
  end

  defp final_report_interrupt_summary(entry) do
    interrupt = Map.get(entry, :interrupt, %{})

    if final_report_interrupt?(interrupt) do
      final_report = final_report_payload(interrupt)

      [
        "Final report: #{final_report_classification(interrupt)}",
        "next_state=#{final_report_detail(final_report, :reported_next_state, "n/a")}",
        "continuations=#{final_report_detail(final_report, :continuation_count, 0)}"
      ]
      |> Enum.join(" · ")
    end
  end

  defp final_report_interrupt?(interrupt) do
    Map.get(interrupt, :reason) == "final_report_invalid" || Map.get(interrupt, "reason") == "final_report_invalid"
  end

  defp final_report_payload(interrupt) do
    Map.get(interrupt, :final_report) || Map.get(interrupt, "final_report") || %{}
  end

  defp final_report_classification(interrupt) do
    Map.get(interrupt, :classification) || Map.get(interrupt, "classification") || "invalid"
  end

  defp final_report_detail(final_report, key, default) do
    Map.get(final_report, key) || Map.get(final_report, Atom.to_string(key)) || default
  end

  defp paused_claim_status(entry) do
    entry = paused_entry(entry)

    if Map.get(entry, :blocks_dispatch) do
      reason = Map.get(entry, :blocked_dispatch_reason) || "paused_claim"
      state_summary = paused_state_summary(entry)
      stale = Map.get(entry, :stale_reason)
      revalidated = Map.get(entry, :revalidated_at)

      ["Blocks dispatch: #{reason}", state_summary, stale && "stale: #{stale}", revalidated && "revalidated: #{revalidated}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
    end
  end

  defp paused_state_summary(entry) do
    paused_entry = paused_entry(entry)

    if Map.has_key?(paused_entry, :paused_state) do
      paused_state = Map.get(paused_entry, :paused_state) || Map.get(paused_entry, :state)
      tracker_state = tracker_state(entry)

      if paused_state == tracker_state do
        "paused_state=#{paused_state || "n/a"}"
      else
        "paused_state=#{paused_state || "n/a"} · tracker_state=#{tracker_state || "n/a"} · tracker-state mismatch"
      end
    end
  end

  defp tracker_state(%{paused: paused}) when is_map(paused), do: Map.get(paused, :tracker_state) || Map.get(paused, :state)
  defp tracker_state(%{running: running}) when is_map(running), do: Map.get(running, :state)
  defp tracker_state(%{retry: retry}) when is_map(retry), do: Map.get(retry, :state) || Map.get(retry, :status)
  defp tracker_state(%{tracker_state: tracker_state, state: state, status: status}), do: tracker_state || state || status
  defp tracker_state(%{tracker_state: tracker_state, state: state}), do: tracker_state || state
  defp tracker_state(%{tracker_state: tracker_state, status: status}), do: tracker_state || status
  defp tracker_state(%{state: state}), do: state
  defp tracker_state(%{status: status}), do: status
  defp tracker_state(_), do: nil

  defp paused_entry(%{paused: paused}) when is_map(paused), do: paused
  defp paused_entry(entry), do: entry

  defp entry_links(entry) when is_map(entry), do: Map.get(entry, :links) || Map.get(entry, "links") || %{}
  defp entry_links(_entry), do: %{}

  defp entry_has_links?(entry) do
    entry_links(entry)
    |> Enum.any?(fn {_group, links} -> link_group_has_items?(links) end)
  end

  defp link_group(entry, group) do
    entry_links(entry)
    |> Map.get(group, %{available: [], unavailable: []})
  end

  defp link_group_has_items?(%{available: available, unavailable: unavailable}) do
    (available || []) != [] or (unavailable || []) != []
  end

  defp link_group_has_items?(_group), do: false

  defp render_entry_links(assigns) do
    ~H"""
    <div class={"entry-link-stack #{if @compact, do: "entry-link-stack-compact", else: ""}"}>
      <%= for {group, label} <- [tracker: "Tracker", review: "Review"] do %>
        <% links = link_group(@entry, group) %>
        <%= if link_group_has_items?(links) do %>
          <div class="entry-link-group">
            <%= if !@compact do %>
              <span class="entry-link-group-label"><%= label %></span>
            <% end %>
            <div class="entry-link-row">
              <%= for link <- links.available || [] do %>
                <a class={entry_link_class(link.kind)} href={link.url} target="_blank" rel="noreferrer noopener" onclick="event.stopPropagation()">
                  <span class="entry-link-icon"><%= link.icon %></span>
                  <span><%= link.label %></span>
                </a>
              <% end %>
            </div>
            <%= for link <- links.unavailable || [] do %>
              <span class="entry-link-missing muted">
                <%= if @compact do %>
                  <%= link.label %> unavailable<%= if link.reason, do: ": #{link.reason}" %>
                <% else %>
                  <%= label %> · <%= link.label %> unavailable<%= if link.reason, do: ": #{link.reason}" %>
                <% end %>
              </span>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp entry_link_class(:linear_issue), do: "entry-link-pill entry-link-pill-linear"
  defp entry_link_class(:github_issue), do: "entry-link-pill entry-link-pill-github"
  defp entry_link_class(:pull_request), do: "entry-link-pill entry-link-pill-review"
  defp entry_link_class(:branch), do: "entry-link-pill entry-link-pill-branch"
  defp entry_link_class(:final_report), do: "entry-link-pill entry-link-pill-report"
  defp entry_link_class(:issue), do: "entry-link-pill entry-link-pill-issue"
  defp entry_link_class(_), do: "entry-link-pill"

  defp humanize_interrupt_reason("repeated_gate_failure"), do: "Gate failure"
  defp humanize_interrupt_reason("action_policy_guidance_required"), do: "Action policy"
  defp humanize_interrupt_reason("final_report_invalid"), do: "Final report"

  defp humanize_interrupt_reason(reason) when is_binary(reason) do
    reason
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize_interrupt_reason(_reason), do: "Paused run"

  defp guidance_severity_class("critical"), do: "state-badge state-badge-danger"
  defp guidance_severity_class("warning"), do: "state-badge state-badge-warning"
  defp guidance_severity_class("info"), do: "state-badge state-badge-active"
  defp guidance_severity_class(_severity), do: "state-badge state-badge-warning"

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

  defp exit_reason_class("completed"), do: "state-badge state-badge-active"
  defp exit_reason_class("handed_off"), do: "state-badge state-badge-handoff"
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

  defp format_model_pct(pct) when is_float(pct), do: "#{Float.round(pct, 1)}%"
  defp format_model_pct(pct) when is_number(pct), do: "#{pct}%"
  defp format_model_pct(_), do: "n/a"

  defp pct_of(part, total) when total > 0, do: Float.round(part / total * 100.0, 1)
  defp pct_of(_part, 0), do: 0.0

  # --- Model routing section ---

  alias Rondo.ModelUsage

  defp model_routing_section(selected_issue_data, nil) do
    model_routing = selected_issue_data[:model_routing]
    adapter = selected_issue_data[:adapter]
    is_map(model_routing) or is_binary(adapter)
  end

  defp model_routing_section(selected_issue_data, selected_runs) when is_list(selected_runs) do
    model_routing = selected_issue_data[:model_routing]
    adapter = selected_issue_data[:adapter]
    has_mr = is_map(model_routing) or is_binary(adapter)
    has_mr or any_run_has_routing?(selected_runs)
  end

  defp any_run_has_routing?(selected_runs) do
    selected_runs != [] and
      Enum.any?(selected_runs, fn r ->
        mr = r[:model_routing] || r["model_routing"]
        is_map(mr) and map_size(mr) > 0
      end)
  end

  defp routing_status(run) when is_map(run) do
    routing = run[:model_routing] || run["model_routing"] || %{}
    routing[:status] || routing["status"]
  end

  defp render_model_routing(selected_issue_data, selected_runs) do
    assigns = %{data: selected_issue_data, runs: selected_runs}

    ~H"""
    <%= if @runs && length(@runs) > 0 do %>
      <div style="margin-bottom: 10px;">
        <%= for {run, idx} <- Enum.with_index(@runs) do %>
          <% model_info = run_model_info(run) %>
          <div style="display: flex; align-items: center; gap: 8px; padding: 4px 0; font-size: 12px;">
            <span class="muted" style="min-width: 48px;">Run <%= idx + 1 %></span>
            <span class={provider_badge_class(model_info.provider)} style="font-size: 10px; padding: 1px 6px; border-radius: 8px;">
              <%= model_info.provider || "unknown" %>
            </span>
            <span class="mono" style="font-size: 11px;"><%= model_info.model || "unknown" %></span>
            <%= if status = routing_status(run) do %>
              <span class="muted" style="font-size: 10px;">(<%= status %>)</span>
            <% end %>
          </div>
        <% end %>
      </div>
      <% active = List.last(@runs) |> run_model_info() %>
      <% past = Enum.drop(@runs, -1) |> Enum.map(&run_model_info/1) |> Enum.uniq_by(& &1.model) %>
      <%= if past != [] do %>
        <div style="margin-top: 6px; padding-top: 8px; border-top: 1px solid var(--border); font-size: 11px;">
          <span class="muted">Historical: </span>
          <%= Enum.map_join(past, ", ", fn mi -> "#{mi.model}" end) %>
        </div>
      <% end %>
      <%= if active.model && Map.has_key?(active, :model) do %>
        <div style="margin-top: 4px; font-size: 11px;">
          <span class="muted">Active: </span>
          <span class={provider_badge_class(active.provider)} style="font-size: 10px; padding: 1px 6px; border-radius: 8px;">
            <%= active.provider || "unknown" %>
          </span>
          <span class="mono" style="font-size: 11px;"><%= active.model %></span>
        </div>
      <% end %>
    <% else %>
      <% model_info = run_model_info(@data) %>
      <div style="display: flex; align-items: center; gap: 8px; font-size: 12px;">
        <span class={provider_badge_class(model_info.provider)} style="font-size: 10px; padding: 1px 6px; border-radius: 8px;">
          <%= model_info.provider || "unknown" %>
        </span>
        <span class="mono" style="font-size: 11px;"><%= model_info.model || model_info.adapter || "unknown" %></span>
        <%= if status = routing_status(@data) do %>
          <span class="muted" style="font-size: 10px;">(<%= status %>)</span>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp run_model_info(run) when is_map(run) do
    mr = run[:model_routing] || run["model_routing"]
    resolved = (is_map(mr) && (mr[:resolved] || mr["resolved"])) || %{}
    model = resolved[:model] || resolved["model"]
    adapter = resolved[:adapter] || resolved["adapter"] || run[:adapter] || run["adapter"]

    %{
      model: model,
      adapter: adapter,
      provider: ModelUsage.provider_from_model(model)
    }
  end

  defp provider_badge_class("codex"), do: "state-badge state-badge-active"
  defp provider_badge_class("openrouter"), do: "state-badge state-badge-warning"
  defp provider_badge_class("pi"), do: "state-badge state-badge-handoff"
  defp provider_badge_class("claude_code"), do: "state-badge state-badge-active"
  defp provider_badge_class("openai"), do: "state-badge state-badge-warning"
  defp provider_badge_class(provider) when is_binary(provider), do: "state-badge"
  defp provider_badge_class(_), do: "state-badge"
end
