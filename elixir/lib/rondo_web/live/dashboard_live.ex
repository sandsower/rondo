defmodule RondoWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Rondo.
  """

  use Phoenix.LiveView, layout: {RondoWeb.Layouts, :app}

  alias Rondo.RunOutcome

  alias RondoWeb.{
    ArchivedRuns,
    DashboardEventStream,
    Endpoint,
    EventInspector,
    ObservabilityPubSub,
    Presenter,
    ResultSummary
  }

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:log_filters, default_log_filters())
      |> assign(:selected_issue, nil)
      |> assign(:selected_issue_data, nil)
      |> assign(:selected_outcome, nil)
      |> assign(:selected_runs, nil)
      |> assign(:selected_run_index, 0)
      |> assign(:selected_run_projection, nil)
      |> assign(:archived_filters, ArchivedRuns.default_filters())
      |> assign(:event_query, "")
      |> assign(:event_category, :all)
      |> assign(:selected_event_index, nil)
      |> assign(:selected_event_view, :summary)
      |> assign(:selected_event_detail, nil)
      |> assign(:show_event_filters, false)
      |> assign(:panel_tab, "overview")
      |> assign(:event_stream_view, DashboardEventStream.build(%{}, nil, nil, 0, %{}))

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

          if entry do
            socket
            |> assign(:selected_issue_data, entry)
            |> assign(:selected_run_projection, selected_run_projection_for(entry))
          else
            socket
          end
      end

    {:noreply, socket |> rebuild_event_stream_view() |> maybe_refresh_selected_event_detail()}
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
      |> assign(:selected_outcome, nil)
      |> assign(:selected_runs, nil)
      |> assign(:selected_run_index, 0)
      |> assign(:panel_tab, default_panel_tab(entry))
      |> assign(:selected_run_projection, selected_run_projection_for(entry))
      |> assign(:selected_event_index, nil)
      |> assign(:selected_event_view, :summary)
      |> assign(:selected_event_detail, nil)
      |> rebuild_event_stream_view(DashboardEventStream.default_filters())
      |> assign(:event_query, "")
      |> assign(:event_category, :all)

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_events", params, socket) do
    filters = event_filters(params)

    visible_event_indexes =
      socket.assigns[:selected_issue_data]
      |> event_entries(filters)
      |> Enum.map(& &1.index)

    socket =
      socket
      |> assign(:event_query, filters.query)
      |> assign(:event_category, filters.category)

    socket =
      if socket.assigns[:selected_event_index] in visible_event_indexes do
        maybe_refresh_selected_event_detail(socket)
      else
        socket
        |> assign(:selected_event_index, nil)
        |> assign(:selected_event_view, :summary)
        |> assign(:selected_event_detail, nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_event", %{"index" => index_str}, socket) do
    case Integer.parse(index_str) do
      {index, ""} when index >= 0 ->
        case EventInspector.select_event_detail(socket.assigns.selected_issue_data, index) do
          {:ok, detail} ->
            {:noreply,
             socket
             |> assign(:selected_event_index, index)
             |> assign(:selected_event_view, :summary)
             |> assign(:selected_event_detail, detail)}

          {:error, _reason} ->
            {:noreply, reset_selected_event(socket)}
        end

      _ ->
        {:noreply, reset_selected_event(socket)}
    end
  end

  @impl true
  def handle_event("toggle_event_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, :selected_event_view, parse_event_view(view))}
  end

  @impl true
  def handle_event("toggle_event_filters", _params, socket) do
    {:noreply, update(socket, :show_event_filters, &(!&1))}
  end

  @impl true
  def handle_event("select_panel_tab", %{"tab" => tab}, socket) when tab in ["overview", "timeline", "guidance"] do
    {:noreply, assign(socket, :panel_tab, tab)}
  end

  @impl true
  def handle_event("select_timeline_step", %{"index" => index_str}, socket) do
    projection = socket.assigns[:selected_run_projection]

    # Re-clicking the selected step toggles the detail pane closed; any parse
    # or lookup failure also resets the selection.
    with {index, ""} when index >= 0 <- Integer.parse(index_str),
         false <- socket.assigns[:selected_event_index] == index,
         {:ok, detail} <- timeline_step_detail(projection, socket.assigns.selected_issue_data, index) do
      {:noreply,
       socket
       |> assign(:selected_event_index, index)
       |> assign(:selected_event_view, :summary)
       |> assign(:selected_event_detail, detail)}
    else
      _ -> {:noreply, reset_selected_event(socket)}
    end
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
     |> assign(:now, DateTime.utc_now())
     |> rebuild_event_stream_view()
     |> maybe_refresh_selected_event_detail()}
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
       |> assign(:selected_outcome, selected_outcome(run_with_log))
       |> assign(:selected_run_index, latest_index)
       |> assign(:selected_runs, group.runs)
       |> assign(:panel_tab, default_panel_tab(run_with_log))
       |> assign(:selected_run_projection, selected_run_projection_for(latest_run))
       |> reset_event_filters()
       |> rebuild_event_stream_view(DashboardEventStream.default_filters())
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
         |> assign(:selected_outcome, selected_outcome(run_with_log))
         |> assign(:selected_run_index, selected_index)
         |> assign(:selected_runs, runs)
         |> assign(:panel_tab, default_panel_tab(run_with_log))
         |> assign(:selected_run_projection, selected_run_projection_for(selected_run))
         |> reset_event_filters()
         |> rebuild_event_stream_view(DashboardEventStream.default_filters())
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
       |> assign(:selected_outcome, selected_outcome(run_with_log))
       |> assign(:selected_run_index, index)
       |> assign(:selected_run_projection, selected_run_projection_for(run))
       |> reset_event_filters()
       |> rebuild_event_stream_view(DashboardEventStream.default_filters())}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("event_stream_filters", params, socket) do
    filters = socket.assigns.event_stream_view.filters |> Map.merge(event_filter_params(params))
    {:noreply, rebuild_event_stream_view(socket, filters)}
  end

  @impl true
  def handle_event("event_stream_facet", %{"facet" => facet}, socket) do
    filters = Map.put(socket.assigns.event_stream_view.filters, :facet, facet)
    {:noreply, rebuild_event_stream_view(socket, filters)}
  end

  @impl true
  def handle_event("event_stream_sort", %{"sort" => sort}, socket) do
    filters = Map.put(socket.assigns.event_stream_view.filters, :sort, sort)
    {:noreply, rebuild_event_stream_view(socket, filters)}
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
  def handle_event("reset_event_filters", _params, socket) do
    {:noreply, rebuild_event_stream_view(socket, DashboardEventStream.default_filters())}
  end

  @impl true
  def handle_event("close_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_issue, nil)
     |> assign(:selected_issue_data, nil)
     |> assign(:selected_outcome, nil)
     |> assign(:selected_runs, nil)
     |> assign(:selected_run_index, 0)
     |> assign(:selected_run_projection, nil)
     |> reset_event_filters()
     |> rebuild_event_stream_view(DashboardEventStream.default_filters())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <h1 class="hero-title">
          Operations Dashboard
        </h1>
        <p class="hero-copy">
          Current state, retry pressure, token usage, and orchestration health for the active Rondo runtime.
        </p>
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
              <details class="chart-card-footnote">
                <summary>By model (<%= map_size(@payload.model_usage.by_model) %> models)</summary>
                <div class="model-breakdown">
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
            <div class="chart-card-header">
              <p class="chart-card-title">Top archived tickets by tokens</p>
              <% archived_ticket_count = length(@payload[:archived] || []) %>
              <span class="muted text-11">
                <%= if archived_ticket_count > Presenter.outcome_chart_limit() do %>
                  Top <%= Presenter.outcome_chart_limit() %> of <%= archived_ticket_count %> tickets · colored by outcome · click a bar to inspect
                <% else %>
                  Colored by outcome · click a bar to inspect
                <% end %>
              </span>
            </div>
            <div class="chart-wrap chart-wrap-tall">
              <canvas id="outcome-chart" phx-hook="OutcomeChart" phx-update="ignore"></canvas>
            </div>
          </div>
        </div>

        <% log_rows = dashboard_log_rows(@payload, @log_filters) %>
        <section id="logs" class="section-card logs-section">
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
              <thead>
                <tr>
                  <th aria-sort={aria_sort(@log_filters, "date")}><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="date">Date <%= sort_indicator(@log_filters, "date") %></button></th>
                  <th aria-sort={aria_sort(@log_filters, "model")}><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="model">Model <%= sort_indicator(@log_filters, "model") %></button></th>
                  <th aria-sort={aria_sort(@log_filters, "provider")}><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="provider">Provider <%= sort_indicator(@log_filters, "provider") %></button></th>
                  <th aria-sort={aria_sort(@log_filters, "app")}><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="app">App <%= sort_indicator(@log_filters, "app") %></button></th>
                  <th aria-sort={aria_sort(@log_filters, "input_tokens")}><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="input_tokens">Input <%= sort_indicator(@log_filters, "input_tokens") %></button></th>
                  <th aria-sort={aria_sort(@log_filters, "output_tokens")}><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="output_tokens">Output <%= sort_indicator(@log_filters, "output_tokens") %></button></th>
                  <th aria-sort={aria_sort(@log_filters, "cost")}><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="cost">Cost <%= sort_indicator(@log_filters, "cost") %></button></th>
                  <th aria-sort={aria_sort(@log_filters, "speed")}><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="speed">Speed <%= sort_indicator(@log_filters, "speed") %></button></th>
                  <th aria-sort={aria_sort(@log_filters, "finish")}><button type="button" class="table-sort-button" phx-click="sort_logs" phx-value-field="finish">Finish <%= sort_indicator(@log_filters, "finish") %></button></th>
                  <th>Source</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- log_rows}
                  class={"data-table-row #{if log_row_selected?(@selected_issue, row), do: "data-table-row-selected", else: ""}"}
                  phx-click={if row.kind == :archived, do: "select_archived", else: "select_issue"}
                  phx-value-identifier={row.identifier}
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

        <section id="guidance" class="section-card">
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
              <table class="data-table">
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

        <section id="sessions" class="section-card">
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
                  >
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <% model_info = run_model_info(entry) %>
                        <div class="model-badge-row">
                          <span class={provider_badge_class(model_info.provider)}><%= model_info.provider || "unknown" %></span>
                          <span class="model-chip"><%= model_info.model || model_info.adapter || "unknown" %></span>
                        </div>
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
                            id={"copy-session-#{entry.issue_identifier}"}
                            phx-hook="CopyButton"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            aria-label={"Copy session ID for #{entry.issue_identifier}"}
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
                          title={result_preview_text(entry.last_result_payload || entry.last_message || to_string(entry.last_event || "n/a"))}
                        ><%= result_preview_text(entry.last_result_payload || entry.last_message || to_string(entry.last_event || "n/a")) %></span>
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

        <section id="retries" class="section-card">
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
              <table class="data-table data-table-wide">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Action</th>
                    <th>Phase</th>
                    <th>PR</th>
                    <th>Blocked</th>
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
                    <td><%= release_loop_display(entry, :action) %></td>
                    <td><%= release_loop_display(entry, :phase) %></td>
                    <td>
                      <%= if release_loop_pr_url(entry) do %>
                        <a class="issue-link" href={release_loop_pr_url(entry)} target="_blank" rel="noreferrer">
                          #<%= release_loop_pr_number(entry) || "n/a" %>
                        </a>
                      <% else %>
                        n/a
                      <% end %>
                    </td>
                    <td><%= release_loop_display(entry, :blocked_reason) %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <%= if Map.get(@payload, :dispatch_blockers, []) != [] do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Dispatch blockers</h2>
                <p class="section-copy">Active issues that the poller is intentionally not starting right now.</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Reason</th>
                    <th>Detail</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- Map.get(@payload, :dispatch_blockers, [])}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier || entry.issue_id || "n/a" %></span>
                        <a :if={entry.issue_identifier} class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                      </div>
                    </td>
                    <td>
                      <span class="state-badge state-badge-warning"><%= entry.blocked_dispatch_reason || "blocked" %></span>
                    </td>
                    <td><%= entry.blocked_dispatch_detail || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <% archived_view = archived_table_view(@payload, @archived_filters) %>
        <section id="archived" class="section-card archived-runs-card">
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
                      <th aria-sort={aria_sort(archived_view.filters, "issue")}><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="issue">Issue <%= sort_indicator(archived_view.filters, "issue") %></button></th>
                      <th aria-sort={aria_sort(archived_view.filters, "project")}><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="project">Project / repo <%= sort_indicator(archived_view.filters, "project") %></button></th>
                      <th aria-sort={aria_sort(archived_view.filters, "status")}><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="status">State / outcome <%= sort_indicator(archived_view.filters, "status") %></button></th>
                      <th aria-sort={aria_sort(archived_view.filters, "started")}><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="started">Started <%= sort_indicator(archived_view.filters, "started") %></button></th>
                      <th aria-sort={aria_sort(archived_view.filters, "ended")}><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="ended">Ended <%= sort_indicator(archived_view.filters, "ended") %></button></th>
                      <th aria-sort={aria_sort(archived_view.filters, "duration")}><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="duration">Duration <%= sort_indicator(archived_view.filters, "duration") %></button></th>
                      <th aria-sort={aria_sort(archived_view.filters, "model")}><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="model">Model / provider <%= sort_indicator(archived_view.filters, "model") %></button></th>
                      <th aria-sort={aria_sort(archived_view.filters, "tokens")}><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="tokens">Tokens / cost <%= sort_indicator(archived_view.filters, "tokens") %></button></th>
                      <th>Links</th>
                      <th aria-sort={aria_sort(archived_view.filters, "result")}><button type="button" class="sort-button" phx-click="sort_archived" phx-value-field="result">Last result <%= sort_indicator(archived_view.filters, "result") %></button></th>
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
                          <% outcome = run[:outcome_display] || %{class: exit_reason_class(run.exit_reason), label: run.status, detail: run.outcome} %>
                          <span class={outcome.class}><%= outcome.label || run.status %></span>
                          <span class="muted event-meta"><%= outcome.detail || run.outcome || "n/a" %></span>
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
      <div class="panel-overlay" phx-click="close_panel" aria-hidden="true"></div>
      <aside
        class="panel-slide"
        role="dialog"
        aria-modal="true"
        aria-label={"Run details for #{@selected_issue}"}
        phx-window-keydown="close_panel"
        phx-key="escape"
      >
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
          <button type="button" class="panel-close" phx-click="close_panel" aria-label="Close details panel">&times;</button>
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
          <% active_tab = effective_panel_tab(@panel_tab, @selected_issue_data) %>
          <div class="panel-tabs" role="tablist">
            <button
              type="button"
              role="tab"
              aria-selected={to_string(active_tab == "overview")}
              class={"panel-tab #{if active_tab == "overview", do: "panel-tab-active", else: ""}"}
              phx-click="select_panel_tab"
              phx-value-tab="overview"
            >
              Overview
            </button>
            <button
              type="button"
              role="tab"
              aria-selected={to_string(active_tab == "timeline")}
              class={"panel-tab #{if active_tab == "timeline", do: "panel-tab-active", else: ""}"}
              phx-click="select_panel_tab"
              phx-value-tab="timeline"
            >
              Timeline <span class="panel-tab-count numeric"><%= @event_stream_view.total_count %></span>
            </button>
            <%= if @selected_issue_data[:interrupt] do %>
              <button
                type="button"
                role="tab"
                aria-selected={to_string(active_tab == "guidance")}
                class={"panel-tab #{if active_tab == "guidance", do: "panel-tab-active", else: ""}"}
                phx-click="select_panel_tab"
                phx-value-tab="guidance"
              >
                Guidance <span class="panel-tab-alert" aria-label="needs attention"></span>
              </button>
            <% end %>
          </div>
        <% end %>

        <div class="panel-body">
          <%= if @selected_issue_data do %>
            <% active_tab = effective_panel_tab(@panel_tab, @selected_issue_data) %>
            <%!-- Panes are CSS-hidden (not unmounted) so chart hooks and any
                 guidance draft survive tab switches. --%>
            <div class={"panel-pane #{if active_tab != "overview", do: "tab-hidden", else: ""}"}>
            <div class="panel-metrics">
              <div class="panel-metric">
                <span class="panel-metric-label">State</span>
                <div class="detail-stack">
                  <span class={state_badge_class(tracker_state(@selected_issue_data) || "n/a")}><%= tracker_state(@selected_issue_data) || "n/a" %></span>
                  <%= if paused_state_summary(@selected_issue_data) do %>
                    <span class="muted text-11"><%= paused_state_summary(@selected_issue_data) %></span>
                  <% end %>
                </div>
              </div>
              <div class="panel-metric">
                <span class="panel-metric-label"><%= selected_time_label(@selected_issue_data) %></span>
                <span class="numeric"><%= selected_time_value(@selected_issue_data, @now) %></span>
              </div>
              <div class="panel-metric">
                <span class="panel-metric-label">Model</span>
                <% model_info = selected_model_info(@selected_issue_data) %>
                <div class="detail-stack">
                  <div class="model-badge-row">
                    <span class={provider_badge_class(model_info.provider)}><%= model_info.provider || "unknown" %></span>
                    <span class="model-chip"><%= model_info.model || model_info.adapter || "unknown" %></span>
                  </div>
                  <%= if model_info.status do %>
                    <span class="muted text-11"><%= model_info.status %></span>
                  <% end %>
                </div>
              </div>
              <div class="panel-metric">
                <span class="panel-metric-label">Token mix</span>
                <% token_usage = selected_token_usage(@selected_issue_data) %>
                <div class="token-stack numeric">
                  <span>In <%= format_int(token_usage.input_tokens) %></span>
                  <span>Out <%= format_int(token_usage.output_tokens) %></span>
                  <span>Cached <%= format_int(token_usage.cached_tokens) %></span>
                  <span>Total <%= format_int(token_usage.total_tokens) %></span>
                </div>
              </div>
              <div class="panel-metric">
                <%= cond do %>
                  <% selected_result_payload(@selected_issue_data) -> %>
                    <span class="panel-metric-label">Last result</span>
                    <span class={"#{result_summary_badge_class(selected_result_payload(@selected_issue_data))} state-badge-preview"}><%= result_preview_text(selected_result_payload(@selected_issue_data)) %></span>
                  <% @selected_issue_data[:finished_at] && @selected_outcome -> %>
                    <span class="panel-metric-label">Result</span>
                    <div class="detail-stack">
                      <span class={@selected_outcome.class}><%= @selected_outcome.label %></span>
                      <%= if @selected_outcome.detail do %>
                        <span class="muted text-11"><%= @selected_outcome.detail %></span>
                      <% end %>
                    </div>
                <% true -> %>
                  <span class="panel-metric-label">Session</span>
                  <span class="mono text-11"><%= @selected_issue_data[:session_id] || "n/a" %></span>
                <% end %>
              </div>
            </div>

            <%= if selected_result_payload(@selected_issue_data) do %>
              <div class="panel-section">
                <p class="panel-metric-label">Last result</p>
                <%= render_result_summary(selected_result_payload(@selected_issue_data)) %>
              </div>
            <% end %>

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

            <%= if @selected_runs && length(@selected_runs) > 0 do %>
              <div class="panel-section">
                <p class="panel-metric-label">Run breakdown</p>
                <%= render_run_breakdown(@selected_runs, @selected_run_index) %>
              </div>
            <% end %>

            <%= if model_routing_section(@selected_issue_data, @selected_runs) do %>
              <div class="panel-section">
                <p class="panel-metric-label">Model routing</p>
                <%= render_model_routing(@selected_issue_data, @selected_runs) %>
              </div>
            <% end %>

            <%= if entry_has_links?(@selected_issue_data) do %>
              <div class="panel-section">
                <p class="panel-metric-label">Links</p>
                <%= render_entry_links(%{entry: @selected_issue_data, compact: false}) %>
              </div>
            <% end %>
            </div>

            <%= if @selected_issue_data[:interrupt] do %>
              <div class={"panel-pane #{if active_tab != "guidance", do: "tab-hidden", else: ""}"}>
              <div class="panel-section">
                <p class="panel-metric-label">Guidance</p>
                <p class="panel-section-copy">
                  <%= get_in(@selected_issue_data, [:interrupt, :question]) || get_in(@selected_issue_data, [:interrupt, :recommendation]) || "Provide operator guidance to resume this paused run." %>
                </p>
                <%= if final_report_interrupt_summary(@selected_issue_data) do %>
                  <p class="panel-section-copy">
                    <%= final_report_interrupt_summary(@selected_issue_data) %>
                  </p>
                <% end %>
                <%= if paused_claim_status(@selected_issue_data) do %>
                  <p class="panel-section-copy">
                    <%= paused_claim_status(@selected_issue_data) %>
                  </p>
                <% end %>
                <form phx-submit="submit_guidance">
                  <input type="hidden" name="issue-id" value={@selected_issue_data[:issue_id]} />
                  <textarea
                    name="guidance"
                    rows="4"
                    placeholder="Tell the agent how to unblock this run..."
                    class="field-textarea"
                  ></textarea>
                  <div class="guidance-actions">
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
              </div>
            <% end %>

            <div class={"panel-pane #{if active_tab != "timeline", do: "tab-hidden", else: ""}"}>
            <div class="panel-stream-header">
              <div class="detail-stack">
                <span class="panel-metric-label">Run timeline</span>
                <span class="muted text-11">
                  <%= @event_stream_view.filtered_count %> / <%= @event_stream_view.total_count %> events
                </span>
                <%!-- Projection fields drop nil values, so every access must tolerate missing keys. --%>
                <%= if @selected_run_projection do %>
                  <span class="muted text-11 mono panel-stream-meta">
                    run <%= entry_value(@selected_run_projection, :run_id) || "n/a" %>
                    · session <%= entry_value(@selected_run_projection, :session_id) || "n/a" %>
                    · <%= entry_value(@selected_run_projection, :status) ||
                      entry_value(@selected_run_projection, :exit_reason) || "n/a" %>
                  </span>
                <% end %>
              </div>
              <div class="panel-stream-actions">
                <button
                  type="button"
                  class={"subtle-button #{if @show_event_filters, do: "btn-active", else: ""}"}
                  phx-click="toggle_event_filters"
                  aria-expanded={to_string(@show_event_filters)}
                  aria-controls="event-stream-filter-form"
                >
                  Filters
                </button>
                <button type="button" class="subtle-button" phx-click="reset_event_filters">Reset</button>
              </div>
            </div>

            <div class="event-toolbar">
              <div class="event-facet-row">
                <%= for {facet, label, count} <- event_facet_tabs(@event_stream_view.facets) do %>
                  <button
                    type="button"
                    class={"event-facet #{if @event_stream_view.filters.facet == facet, do: "event-facet-active", else: ""}"}
                    phx-click="event_stream_facet"
                    phx-value-facet={facet}
                  >
                    <%= label %> <span><%= count %></span>
                  </button>
                <% end %>
              </div>

              <form :if={@show_event_filters} id="event-stream-filter-form" class="event-filter-popover" phx-change="event_stream_filters" phx-submit="event_stream_filters">
                <input type="hidden" name="issue" value={@selected_issue || ""} />
                <%= if is_list(@selected_runs) and @selected_runs != [] do %>
                  <input type="hidden" name="run" value={@selected_run_index} />
                <% end %>

                <div class="event-filter-grid">
                  <label class="event-search-field event-filter-span-2">
                    <span>Search</span>
                    <input
                      type="search"
                      name="query"
                      value={@event_stream_view.filters.query}
                      placeholder="Search event type, summary, issue, provider, model..."
                      phx-debounce="300"
                    />
                  </label>

                  <label>
                    <span>Issue / project</span>
                    <input type="search" name="scope" value={@event_stream_view.filters.scope} placeholder="Issue, project, or run text" />
                  </label>

                  <label>
                    <span>Facet</span>
                    <select name="facet">
                      <option value="all" selected={@event_stream_view.filters.facet == "all"}>All</option>
                      <%= for {facet, label, _count} <- event_facet_tabs(@event_stream_view.facets) do %>
                        <%= if facet != "all" do %>
                          <option value={facet} selected={@event_stream_view.filters.facet == facet}><%= label %></option>
                        <% end %>
                      <% end %>
                    </select>
                  </label>

                  <label>
                    <span>Kind</span>
                    <select name="kind">
                      <option value="all" selected={@event_stream_view.filters.kind == "all"}>All</option>
                      <%= for kind <- @event_stream_view.options.kinds do %>
                        <option value={kind} selected={@event_stream_view.filters.kind == kind}><%= kind %></option>
                      <% end %>
                    </select>
                  </label>

                  <label>
                    <span>Status</span>
                    <select name="status">
                      <option value="all" selected={@event_stream_view.filters.status == "all"}>All</option>
                      <%= for status <- @event_stream_view.options.statuses do %>
                        <option value={status} selected={@event_stream_view.filters.status == status}><%= status %></option>
                      <% end %>
                    </select>
                  </label>

                  <label>
                    <span>Provider</span>
                    <select name="provider">
                      <option value="all" selected={@event_stream_view.filters.provider == "all"}>All</option>
                      <%= for provider <- @event_stream_view.options.providers do %>
                        <option value={provider} selected={@event_stream_view.filters.provider == provider}><%= provider %></option>
                      <% end %>
                    </select>
                  </label>

                  <label>
                    <span>Model</span>
                    <select name="model">
                      <option value="all" selected={@event_stream_view.filters.model == "all"}>All</option>
                      <%= for model <- @event_stream_view.options.models do %>
                        <option value={model} selected={@event_stream_view.filters.model == model}><%= model %></option>
                      <% end %>
                    </select>
                  </label>

                  <label>
                    <span>Run state</span>
                    <select name="run_state">
                      <option value="all" selected={@event_stream_view.filters.run_state == "all"}>All</option>
                      <%= for run_state <- @event_stream_view.options.run_states do %>
                        <option value={run_state} selected={@event_stream_view.filters.run_state == run_state}><%= run_state %></option>
                      <% end %>
                    </select>
                  </label>

                  <label>
                    <span>Result</span>
                    <select name="result">
                      <option value="all" selected={@event_stream_view.filters.result == "all"}>All</option>
                      <%= for result <- @event_stream_view.options.results do %>
                        <option value={result} selected={@event_stream_view.filters.result == result}><%= result %></option>
                      <% end %>
                    </select>
                  </label>

                  <label>
                    <span>From (UTC)</span>
                    <input type="datetime-local" name="from" value={datetime_local_value(@event_stream_view.filters.from)} />
                  </label>

                  <label>
                    <span>To (UTC)</span>
                    <input type="datetime-local" name="to" value={datetime_local_value(@event_stream_view.filters.to)} />
                  </label>

                  <label>
                    <span>Sort</span>
                    <select name="sort">
                      <%= for {value, label} <- event_sort_options() do %>
                        <option value={value} selected={@event_stream_view.filters.sort == value}><%= label %></option>
                      <% end %>
                    </select>
                  </label>
                </div>
              </form>

              <div class="event-active-filters">
                <%= for chip <- active_event_filter_chips(@event_stream_view.filters) do %>
                  <span class="event-filter-chip"><%= chip %></span>
                <% end %>
              </div>
            </div>

            <%= if @event_stream_view.total_count == 0 do %>
              <p class="empty-state">Waiting for agent activity...</p>
            <% else %>
              <%= if @event_stream_view.filtered_count == 0 do %>
                <p class="empty-state">No events match the current filters.</p>
              <% else %>
                <div class={"event-inspector-split #{if is_nil(@selected_event_detail), do: "event-inspector-split-single", else: ""}"}>
                  <div class="event-stream" id="event-stream">
                    <div class="event-table-wrap" id="event-stream-scroll" phx-hook="ScrollBottom">
                      <table class="event-table">
                        <thead>
                          <tr>
                            <th>
                              <button type="button" class="event-sort-button" phx-click="event_stream_sort" phx-value-sort={toggle_sort(@event_stream_view.filters.sort, "time")}>Time</button>
                            </th>
                            <th>
                              <button type="button" class="event-sort-button" phx-click="event_stream_sort" phx-value-sort={toggle_sort(@event_stream_view.filters.sort, "kind")}>Kind</button>
                            </th>
                            <th>
                              <button type="button" class="event-sort-button" phx-click="event_stream_sort" phx-value-sort={toggle_sort(@event_stream_view.filters.sort, "status")}>Status</button>
                            </th>
                            <th class="numeric">Tokens</th>
                            <th>
                              <button type="button" class="event-sort-button" phx-click="event_stream_sort" phx-value-sort={toggle_sort(@event_stream_view.filters.sort, "summary")}>Summary</button>
                            </th>
                            <th>Context</th>
                          </tr>
                        </thead>
                        <tbody>
                          <%= for row <- @event_stream_view.rows do %>
                            <% selected? = is_integer(row.step_index) and @selected_event_index == row.step_index %>
                            <tr
                              class={"event-table-row-clickable #{if selected?, do: "event-table-row-selected", else: ""}"}
                              phx-click={if is_integer(row.step_index), do: "select_timeline_step"}
                              phx-value-index={row.step_index}
                              title="Click to inspect"
                            >
                              <td class="mono muted event-time"><%= format_event_time(row.at) %></td>
                              <td>
                                <span class={row.kind_class}><%= row.kind %></span>
                              </td>
                              <td>
                                <span class={row.status_class}><%= row.status %></span>
                              </td>
                              <td class="numeric event-tokens">
                                <div class="detail-stack">
                                  <span><%= if row.tokens_delta, do: "+#{format_int(row.tokens_delta)}", else: "-" %></span>
                                  <%= if row.duration_ms do %>
                                    <span class="muted event-meta"><%= format_duration_ms(row.duration_ms) %></span>
                                  <% end %>
                                </div>
                              </td>
                              <td>
                                <div class="event-summary">
                                  <%= render_event_message(row.summary) %>
                                </div>
                              </td>
                              <td>
                                <div class="event-context">
                                  <span><%= row.issue_identifier || "n/a" %></span>
                                  <span><%= event_context_label(row) %></span>
                                  <%= if row.artifacts != [] do %>
                                    <span class="event-artifacts"><%= Enum.join(row.artifacts, " · ") %></span>
                                  <% end %>
                                </div>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                  </div>

                  <%= if @selected_event_detail do %>
                    <div class="event-detail-panel">
                      <div class="event-detail-header">
                        <div class="detail-stack">
                          <span class="event-row-category"><%= @selected_event_detail[:category_label] || "Event" %></span>
                          <span class="mono text-11 muted"><%= @selected_event_detail[:at] || "n/a" %></span>
                        </div>
                        <button
                          type="button"
                          class="panel-close"
                          phx-click="select_timeline_step"
                          phx-value-index={@selected_event_index}
                          aria-label="Close event detail"
                        >
                          &times;
                        </button>
                      </div>
                      <div class="event-detail-body">
                        <div class="event-detail-summary">
                          <span class="event-summary"><%= render_event_message(to_string(@selected_event_detail[:summary] || "")) %></span>
                        </div>

                        <%= if (@selected_event_detail[:structured_fields] || []) != [] do %>
                          <div class="event-detail-field-list">
                            <%= for {label, value} <- @selected_event_detail.structured_fields do %>
                              <div class="event-detail-field">
                                <span class="result-field-label"><%= label %></span>
                                <span class="event-detail-value mono"><%= value %></span>
                              </div>
                            <% end %>
                          </div>
                        <% end %>

                        <%= if (@selected_event_detail[:artifact_links] || []) != [] do %>
                          <div class="event-detail-artifacts-inline">
                            <span class="result-field-label">Artifacts</span>
                            <%= for artifact <- @selected_event_detail.artifact_links do %>
                              <span class="event-artifact-path" title={artifact.path}>
                                <%= artifact.label %> · <%= artifact.path %>
                              </span>
                            <% end %>
                          </div>
                        <% end %>

                        <%= if @selected_event_detail[:raw_json] do %>
                          <details class="result-raw-collapse">
                            <summary class="muted">Raw JSON</summary>
                            <div class="result-actions">
                              <button
                                type="button"
                                class="subtle-button"
                                id={"copy-event-raw-#{@selected_event_index}"}
                                phx-hook="CopyButton"
                                data-label="Copy raw"
                                data-copy={@selected_event_detail.raw_json}
                              >
                                Copy raw
                              </button>
                            </div>
                            <pre class="code-panel result-pre"><%= @selected_event_detail.raw_json %></pre>
                          </details>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
            </div>
          <% else %>
            <p class="empty-state">Issue not currently running.</p>
          <% end %>
        </div>
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

  defp aria_sort(%{sort_by: field, sort_dir: "asc"}, field), do: "ascending"
  defp aria_sort(%{sort_by: field, sort_dir: "desc"}, field), do: "descending"
  defp aria_sort(_filters, _field), do: nil

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

    width =
      if total_tokens > 0 do
        total_tokens |> :math.log10() |> Kernel.*(20) |> round() |> min(100) |> max(8)
      else
        8
      end

    "width: #{width}%"
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

          run
          |> Map.merge(full_entry)
          |> Map.put(:event_log, event_log)

        _ ->
          Map.put(run, :event_log, [])
      end
    else
      Map.put(run, :event_log, [])
    end
  end

  @spec selected_run_projection_for_test(map() | nil) :: map() | nil
  def selected_run_projection_for_test(run), do: selected_run_projection_for(run)

  @spec archive_activity_style_for_test(map()) :: String.t()
  def archive_activity_style_for_test(run), do: archive_activity_style(run)

  # Paused runs open straight on the actionable tab; everything else starts
  # at the overview.
  defp default_panel_tab(data) when is_map(data), do: if(data[:interrupt], do: "guidance", else: "overview")
  defp default_panel_tab(_data), do: "overview"

  # Guard against a stale "guidance" tab after the interrupt clears.
  defp effective_panel_tab("guidance", data) do
    if is_map(data) and data[:interrupt], do: "guidance", else: "overview"
  end

  defp effective_panel_tab(tab, _data) when tab in ["overview", "timeline"], do: tab
  defp effective_panel_tab(_tab, _data), do: "overview"

  # Run timelines are no longer shipped in the state payload; project the
  # selected run lazily (disk reads happen only for the run being inspected).
  defp selected_run_projection_for(run), do: Presenter.run_projection(run)

  defp entry_value(entry, key) when is_map(entry) and is_atom(key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp entry_value(_entry, _key), do: nil

  @dashboard_query_keys ~w(issue run query scope facet kind status provider model run_state result from to sort)

  @spec dashboard_query_params(map()) :: map()
  def dashboard_query_params(params) when is_map(params) do
    params
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = to_string(key)

      cond do
        key not in @dashboard_query_keys -> acc
        is_nil(value) -> acc
        true -> Map.put(acc, key, to_string(value))
      end
    end)
  end

  def dashboard_query_params(_), do: %{}

  # The normalized filters map is atom-keyed; string keys from form params
  # would be shadowed by the stale atom entries in normalize_filters/1.
  defp event_filter_params(params) do
    params
    |> dashboard_query_params()
    |> Map.drop(["issue", "run"])
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp rebuild_event_stream_view(socket, filters \\ nil) do
    filters =
      filters || get_in(socket.assigns, [:event_stream_view, :filters]) ||
        DashboardEventStream.default_filters()

    assign(
      socket,
      :event_stream_view,
      DashboardEventStream.build(
        %{run_timelines: List.wrap(socket.assigns[:selected_run_projection])},
        socket.assigns.selected_issue_data,
        socket.assigns.selected_runs,
        socket.assigns.selected_run_index,
        filters
      )
    )
  end

  defp event_facet_tabs(facets) do
    [{"all", "All", total_facet_count(facets)} | DashboardEventStream.facet_choices(facets)]
  end

  defp total_facet_count(facets), do: Map.values(facets) |> Enum.sum()

  defp active_event_filter_chips(filters) do
    [
      chip(filters.query, "Search: "),
      chip(filters.scope, "Issue/project: "),
      chip(filters.facet, "Facet: ", "all"),
      chip(filters.kind, "Kind: ", "all"),
      chip(filters.status, "Status: ", "all"),
      chip(filters.provider, "Provider: ", "all"),
      chip(filters.model, "Model: ", "all"),
      chip(filters.run_state, "Run state: ", "all"),
      chip(filters.result, "Result: ", "all"),
      chip(filters.from, "From: "),
      chip(filters.to, "To: ")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp chip(value, prefix, skip_value \\ nil) do
    cond do
      blank?(value) -> nil
      skip_value != nil and value == skip_value -> nil
      true -> "#{prefix}#{value}"
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp event_sort_options do
    [
      {"time_asc", "Time ↑"},
      {"time_desc", "Time ↓"},
      {"kind_asc", "Kind ↑"},
      {"kind_desc", "Kind ↓"},
      {"status_asc", "Status ↑"},
      {"status_desc", "Status ↓"},
      {"summary_asc", "Summary ↑"},
      {"summary_desc", "Summary ↓"}
    ]
  end

  defp toggle_sort(current, field) do
    field = if field in ["time", "kind", "status", "summary"], do: field, else: "time"
    current = current || "time_asc"
    direction = if String.starts_with?(current, "#{field}_") and String.ends_with?(current, "_asc"), do: "desc", else: "asc"
    "#{field}_#{direction}"
  end

  defp datetime_local_value(nil), do: ""
  defp datetime_local_value(""), do: ""

  defp datetime_local_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> Calendar.strftime(dt, "%Y-%m-%dT%H:%M")
      _ -> value
    end
  end

  defp datetime_local_value(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%dT%H:%M")
  defp datetime_local_value(_), do: ""

  defp event_context_label(row) do
    provider_model =
      case {Map.get(row, :provider), Map.get(row, :model)} do
        {nil, nil} -> nil
        {provider, nil} -> provider
        {nil, model} -> model
        {provider, model} -> "#{provider}/#{model}"
      end

    [provider_model, Map.get(row, :action), Map.get(row, :run_state)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp find_issue_entry(payload, identifier) do
    [:needs_guidance, :paused, :running, :retrying]
    |> Enum.flat_map(&Map.get(payload, &1, []))
    |> Enum.find(&(&1.issue_identifier == identifier))
  end

  defp default_log_filters do
    %{query: "", status: "all", window: "all", sort_by: "date", sort_dir: "desc"}
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

  defp load_payload do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())

    # Ticket groupings are derived here (references into archived_table rows,
    # no deep copy) so the API state payload stays lean.
    Map.put(payload, :archived, Presenter.archived_groups(Map.get(payload, :archived_table, [])))
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
    get_in(selected_issue_data, [:tokens, :total_tokens]) || 0
  end

  defp selected_event_log(selected_issue_data) do
    Map.get(selected_issue_data, :event_log, []) || []
  end

  defp event_entries(selected_issue_data, filters) do
    EventInspector.event_entries(selected_issue_data, filters)
  end

  defp event_filters(params) when is_map(params) do
    %{
      query: Map.get(params, "event_query") || Map.get(params, :event_query) || "",
      category: parse_event_category(Map.get(params, "event_category") || Map.get(params, :event_category))
    }
  end

  @event_category_map %{
    "all" => :all,
    "prompt" => :prompt,
    "tool" => :tool,
    "result" => :result,
    "gate" => :gate,
    "system" => :system,
    "other" => :other
  }

  defp parse_event_category(nil), do: :all
  defp parse_event_category(category) when is_atom(category), do: category
  defp parse_event_category(category) when is_binary(category), do: Map.get(@event_category_map, category, :all)
  defp parse_event_category(category), do: category |> to_string() |> parse_event_category()

  defp parse_event_view("raw"), do: :raw
  defp parse_event_view(_), do: :summary

  defp maybe_refresh_selected_event_detail(%{assigns: %{selected_issue_data: data, selected_event_index: index}} = socket)
       when not is_nil(index) and is_map(data) do
    case timeline_step_detail(socket.assigns[:selected_run_projection], data, index) do
      {:ok, detail} -> assign(socket, :selected_event_detail, detail)
      {:error, _reason} -> assign(socket, :selected_event_detail, nil)
    end
  end

  defp maybe_refresh_selected_event_detail(socket), do: socket

  # Resolve a clicked timeline row to a rich detail view. Timeline steps that
  # originate from the event log get the full raw-event inspector treatment;
  # checkpoint steps load their checkpoint JSON from the run ledger on disk;
  # everything else falls back to the step's own data.
  defp timeline_step_detail(projection, data, index) do
    timeline = entry_value(projection, :timeline) || []

    case Enum.at(timeline, index) do
      # No projection timeline: rows were built straight from the event log.
      nil -> EventInspector.select_event_detail(data, index)
      step -> step_detail(step, data)
    end
  end

  defp step_detail(step, data) do
    source = entry_value(step, :source) || %{}

    case {entry_value(source, :kind), entry_value(source, :event_index)} do
      {"event_log", event_index} when is_integer(event_index) ->
        case EventInspector.select_event_detail(data, event_index) do
          {:ok, detail} -> {:ok, detail}
          {:error, _} -> {:ok, step_fallback_detail(step, source)}
        end

      {"checkpoint", _} ->
        {:ok, checkpoint_detail(step, source)}

      _ ->
        {:ok, step_fallback_detail(step, source)}
    end
  end

  defp checkpoint_detail(step, source) do
    run_dir = entry_value(step, :run_dir)
    rel_path = entry_value(source, :path)

    raw_json =
      with true <- is_binary(run_dir) and is_binary(rel_path),
           {:ok, content} <- File.read(Path.join(run_dir, rel_path)),
           {:ok, decoded} <- Jason.decode(content) do
        decoded |> Jason.encode!(pretty: true) |> Rondo.Redaction.redact()
      else
        _ -> nil
      end

    step
    |> step_fallback_detail(source)
    |> Map.merge(%{category_label: "Checkpoint", raw_json: raw_json, raw_available?: is_binary(raw_json)})
  end

  defp step_fallback_detail(step, source) do
    raw_json =
      case Jason.encode(step, pretty: true) do
        {:ok, json} -> Rondo.Redaction.redact(json)
        {:error, _} -> nil
      end

    %{
      at: entry_value(step, :at),
      event: entry_value(step, :kind),
      display_event: entry_value(step, :kind),
      category_label: step_source_label(source),
      summary: entry_value(step, :summary) || entry_value(step, :outcome) || entry_value(step, :kind),
      structured_fields:
        [
          {"Timestamp", entry_value(step, :at)},
          {"Kind", entry_value(step, :kind)},
          {"Status", entry_value(step, :status)},
          {"Phase", entry_value(step, :phase)},
          {"Duration", step_duration_label(step)},
          {"Session", entry_value(step, :session_id)},
          {"Run", entry_value(step, :run_id)},
          {"Source", entry_value(source, :path) || entry_value(source, :kind)}
        ]
        |> Enum.reject(fn {_label, value} -> value in [nil, ""] end),
      artifact_links: step_artifact_links(step),
      raw_json: raw_json,
      raw_available?: is_binary(raw_json),
      has_redacted_content?: false
    }
  end

  defp step_source_label(source) do
    case entry_value(source, :kind) do
      "checkpoint" -> "Checkpoint"
      "event_log" -> "Event"
      "manifest" -> "Manifest"
      kind when is_binary(kind) -> String.capitalize(kind)
      _ -> "Timeline step"
    end
  end

  defp step_duration_label(step) do
    case entry_value(step, :duration_ms) do
      ms when is_integer(ms) and ms > 0 -> format_duration_ms(ms)
      _ -> nil
    end
  end

  defp step_artifact_links(step) do
    case entry_value(step, :artifacts) do
      artifacts when is_list(artifacts) -> Enum.flat_map(artifacts, &artifact_link/1)
      _ -> []
    end
  end

  defp artifact_link(artifact) do
    path = entry_value(artifact, :path)
    kind = entry_value(artifact, :kind) || "artifact"

    if is_binary(path), do: [%{label: to_string(kind), path: path}], else: []
  end

  defp reset_selected_event(socket) do
    socket
    |> assign(:selected_event_index, nil)
    |> assign(:selected_event_view, :summary)
    |> assign(:selected_event_detail, nil)
  end

  defp reset_event_filters(socket) do
    socket
    |> assign(:selected_event_index, nil)
    |> assign(:selected_event_view, :summary)
    |> assign(:selected_event_detail, nil)
    |> assign(:event_query, "")
    |> assign(:event_category, :all)
  end

  defp selected_outcome(entry) do
    Map.get(entry, :outcome_display) || RunOutcome.display(entry)
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

  defp release_loop_display(entry, key) do
    entry
    |> get_in([:release_loop, key])
    |> case do
      nil -> "n/a"
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  defp release_loop_pr_url(entry), do: get_in(entry, [:release_loop, :pr, :url])
  defp release_loop_pr_number(entry), do: get_in(entry, [:release_loop, :pr, :number])

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

  defp format_duration(started_at, finished_at) do
    with %DateTime{} = s <- to_datetime(started_at),
         %DateTime{} = f <- to_datetime(finished_at) do
      format_runtime_seconds(DateTime.diff(f, s, :second))
    else
      _ -> "n/a"
    end
  end

  defp to_datetime(%DateTime{} = dt), do: dt

  defp to_datetime(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp to_datetime(_timestamp), do: nil

  defp exit_reason_class("completed"), do: "state-badge state-badge-active"
  defp exit_reason_class("handed_off"), do: "state-badge state-badge-handoff"
  defp exit_reason_class(_), do: "state-badge state-badge-danger"

  defp render_event_message(nil), do: ""
  defp render_event_message(""), do: ""

  defp render_event_message(text) when is_binary(text) do
    text
    |> Rondo.Redaction.redact()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(~r/`([^`]+)`/, "<code>\\1</code>")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
    |> Phoenix.HTML.raw()
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
    is_map(model_routing) or is_binary(adapter) or has_model_switches?(selected_issue_data)
  end

  defp model_routing_section(selected_issue_data, selected_runs) when is_list(selected_runs) do
    model_routing = selected_issue_data[:model_routing]
    adapter = selected_issue_data[:adapter]
    has_mr = is_map(model_routing) or is_binary(adapter)
    has_mr or any_run_has_routing?(selected_runs) or has_model_switches?(selected_issue_data)
  end

  defp any_run_has_routing?(selected_runs) do
    selected_runs != [] and
      Enum.any?(selected_runs, fn r ->
        mr = r[:model_routing] || r["model_routing"]
        is_map(mr) and map_size(mr) > 0
      end)
  end

  defp has_model_switches?(issue_data) do
    selected_event_log(issue_data)
    |> model_change_events()
    |> Enum.any?()
  end

  defp routing_status(run) when is_map(run) do
    routing = run[:model_routing] || run["model_routing"] || %{}
    routing[:status] || routing["status"]
  end

  defp render_run_breakdown(runs, selected_index) do
    assigns = %{runs: runs, selected_index: selected_index}

    ~H"""
    <div class="table-wrap">
      <table class="data-table run-breakdown-table">
        <thead>
          <tr>
            <th>Run</th>
            <th>Started</th>
            <th class="numeric">Duration</th>
            <th>Model</th>
            <th class="numeric">Turns</th>
            <th class="numeric">In</th>
            <th class="numeric">Out</th>
            <th class="numeric">Total</th>
            <th class="numeric">Cost</th>
            <th>Outcome</th>
          </tr>
        </thead>
        <tbody>
          <%= for {run, idx} <- Enum.with_index(@runs) do %>
            <% model_info = run_model_info(run) %>
            <% outcome = run[:outcome_display] || %{class: exit_reason_class(run[:exit_reason]), label: run[:status] || run[:exit_reason], detail: nil} %>
            <tr
              class={"data-table-row #{if idx == @selected_index, do: "data-table-row-selected", else: ""}"}
              phx-click="select_run"
              phx-value-index={idx}
            >
              <td class="numeric">#<%= idx + 1 %></td>
              <td class="mono muted"><%= format_archive_datetime(run[:started_at]) %></td>
              <td class="numeric"><%= format_duration_ms(run[:duration_ms]) %></td>
              <td>
                <div class="model-badge-row">
                  <span class={"#{provider_badge_class(model_info.provider)} state-badge-sm"}><%= model_info.provider || "unknown" %></span>
                  <span class="model-chip"><%= model_info.model || model_info.adapter || "unknown" %></span>
                </div>
              </td>
              <td class="numeric"><%= format_int(run[:turn_count]) %></td>
              <td class="numeric"><%= format_int(get_in(run, [:tokens, :input_tokens])) %></td>
              <td class="numeric"><%= format_int(get_in(run, [:tokens, :output_tokens])) %></td>
              <td class="numeric"><%= format_int(get_in(run, [:tokens, :total_tokens])) %></td>
              <td class="numeric"><%= run_cost_label(run[:cost]) %></td>
              <td><span class={outcome.class}><%= outcome.label || "n/a" %></span></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp run_cost_label(cost) when is_number(cost) and cost > 0, do: "$#{:erlang.float_to_binary(cost / 1.0, decimals: 4)}"
  defp run_cost_label(_cost), do: "n/a"

  defp render_model_routing(selected_issue_data, selected_runs) do
    assigns = %{data: selected_issue_data, runs: selected_runs}

    ~H"""
    <% stream_switches = model_change_events(Map.get(@data, :event_log, [])) %>
    <% current_source = if is_list(@runs) and @runs != [], do: List.last(@runs), else: @data %>
    <% current_model = run_model_info(current_source) %>

    <div class="model-routing-card">
      <div class="model-routing-summary">
        <span class="muted text-11">Current</span>
        <span class={"#{provider_badge_class(current_model.provider)} state-badge-sm"}>
          <%= current_model.provider || "unknown" %>
        </span>
        <span class="model-chip"><%= current_model.model || current_model.adapter || "unknown" %></span>
        <%= if status = routing_status(current_source) do %>
          <span class="muted text-10">(<%= status %>)</span>
        <% end %>
      </div>


      <%= if stream_switches != [] do %>
        <div class="model-timeline">
          <div class="model-timeline-heading">Stream switches</div>
          <%= for switch <- stream_switches do %>
            <div class="model-timeline-row">
              <span class="mono model-timeline-at"><%= if switch.at, do: format_event_time(switch.at), else: "n/a" %></span>
              <span class={provider_badge_class(switch.provider)}><%= switch.provider || "unknown" %></span>
              <span class="model-chip"><%= switch.model || "unknown" %></span>
              <span class="muted model-timeline-boundary"><%= switch.message || "model change" %></span>
              <span class="model-timeline-tokens numeric"><%= format_int(switch.cumulative_tokens) %> tokens spent</span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp selected_result_payload(selected_issue_data) when is_map(selected_issue_data) do
    Map.get(selected_issue_data, :final_report) ||
      get_in(selected_issue_data, [:interrupt, :final_report]) ||
      Map.get(selected_issue_data, :last_result_payload) ||
      Map.get(selected_issue_data, :last_message)
  end

  defp selected_result_payload(_selected_issue_data), do: nil

  defp result_preview_text(nil), do: "n/a"
  defp result_preview_text(result), do: ResultSummary.preview(result)

  defp result_summary_badge_class(:final_report), do: "state-badge state-badge-active"
  defp result_summary_badge_class(:json), do: "state-badge state-badge-warning"
  defp result_summary_badge_class(:text), do: "state-badge"
  defp result_summary_badge_class(nil), do: "state-badge"

  defp result_summary_badge_class(result) do
    case ResultSummary.describe(result).kind do
      :final_report -> "state-badge state-badge-active"
      :json -> "state-badge state-badge-warning"
      :text -> "state-badge"
    end
  end

  defp render_result_summary(result) do
    assigns = %{summary: ResultSummary.describe(result)}

    ~H"""
    <div class="result-summary">
      <span class={"#{result_summary_badge_class(@summary.kind)} state-badge-preview"}><%= @summary.preview %></span>

      <%= if @summary.fields != [] do %>
        <div class="result-fields">
          <%= for field <- @summary.fields do %>
            <div class="result-field">
              <span class="result-field-label"><%= field.label %></span>
              <span class="result-field-value"><%= field.value %></span>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @summary.pretty do %>
        <details class="result-raw-collapse">
          <summary class="muted">Raw JSON</summary>
          <div class="result-actions">
            <button
              type="button"
              class="subtle-button"
              id="copy-result-raw"
              phx-hook="CopyButton"
              data-label="Copy raw"
              data-copy={@summary.copy_text}
            >
              Copy raw
            </button>
          </div>
          <pre class="code-panel result-pre"><%= @summary.pretty %></pre>
        </details>
      <% else %>
        <div class="result-actions">
          <button
            type="button"
            class="subtle-button"
            id="copy-result-text"
            phx-hook="CopyButton"
            data-label="Copy text"
            data-copy={@summary.copy_text}
          >
            Copy text
          </button>
        </div>
        <pre class="code-panel result-pre"><%= @summary.raw %></pre>
      <% end %>
    </div>
    """
  end

  defp run_model_info(run) when is_map(run) do
    mr = run[:model_routing] || run["model_routing"]
    resolved = model_routing_resolved(mr)
    model = resolved_model(resolved) || run[:model] || run["model"]
    adapter = resolved_adapter(resolved) || run[:adapter] || run["adapter"]

    %{
      model: model,
      adapter: adapter,
      provider: ModelUsage.provider_from_model(model),
      status: routing_status(run)
    }
  end

  defp model_routing_resolved(mr) when is_map(mr), do: mr[:resolved] || mr["resolved"]
  defp model_routing_resolved(_mr), do: nil

  defp resolved_model(resolved) when is_map(resolved), do: resolved[:model] || resolved["model"]
  defp resolved_model(_resolved), do: nil

  defp resolved_adapter(resolved) when is_map(resolved), do: resolved[:adapter] || resolved["adapter"]
  defp resolved_adapter(_resolved), do: nil

  defp selected_model_info(selected_issue_data) when is_map(selected_issue_data) do
    run_model_info(selected_issue_data)
  end

  defp selected_model_info(_selected_issue_data), do: %{model: nil, adapter: nil, provider: nil, status: nil}

  defp selected_token_usage(selected_issue_data) do
    case selected_issue_data |> selected_event_log() |> event_token_totals() do
      nil ->
        token_usage_from_entry(selected_issue_data)

      totals ->
        if token_totals_zero?(totals) and selected_total_tokens(selected_issue_data) > 0 do
          token_usage_from_entry(selected_issue_data)
        else
          totals
        end
    end
  end

  defp model_change_events(log) when is_list(log) do
    {events, _cumulative} =
      Enum.reduce(log, {[], 0}, fn entry, {events, cumulative} ->
        cumulative = cumulative + entry_total_tokens(entry)

        case Map.get(entry, :model_change) do
          nil ->
            {events, cumulative}

          change ->
            event = %{
              at: Map.get(entry, :at),
              provider: Map.get(change, :provider),
              model: Map.get(change, :model),
              message: Map.get(entry, :message),
              tokens: Map.get(entry, :tokens),
              cumulative_tokens: cumulative
            }

            {[event | events], cumulative}
        end
      end)

    Enum.reverse(events)
  end

  defp model_change_events(_log), do: []

  defp entry_total_tokens(entry) do
    case Map.get(entry, :tokens) do
      nil ->
        0

      tokens ->
        usage = token_usage_from_event(tokens)
        usage.total_tokens || (usage.input_tokens || 0) + (usage.output_tokens || 0)
    end
  end

  defp token_usage_from_entry(%{} = selected_issue_data) do
    tokens = Map.get(selected_issue_data, :tokens) || Map.get(selected_issue_data, "tokens") || %{}

    %{
      input_tokens: token_integer(tokens, [:input_tokens, "input_tokens", :input, "input"]),
      output_tokens: token_integer(tokens, [:output_tokens, "output_tokens", :output, "output"]),
      cached_tokens: cache_tokens(tokens),
      total_tokens: token_integer(tokens, [:total_tokens, "total_tokens", :total, "total"])
    }
    |> normalize_token_totals()
  end

  defp event_token_totals(log) when is_list(log) do
    totals =
      Enum.reduce(log, nil, fn entry, acc ->
        case Map.get(entry, :tokens) do
          nil -> acc
          tokens -> merge_token_totals(acc, token_usage_from_event(tokens))
        end
      end)

    if is_nil(totals), do: nil, else: normalize_token_totals(totals)
  end

  defp event_token_totals(_log), do: nil

  defp token_usage_from_event(tokens) when is_map(tokens) do
    %{
      input_tokens: token_integer(tokens, [:input_tokens, "input_tokens", :input, "input"]),
      output_tokens: token_integer(tokens, [:output_tokens, "output_tokens", :output, "output"]),
      cached_tokens: cache_tokens(tokens),
      total_tokens: token_integer(tokens, [:total_tokens, "total_tokens", :total, "total"])
    }
  end

  defp token_usage_from_event(_tokens), do: %{input_tokens: nil, output_tokens: nil, cached_tokens: nil, total_tokens: nil}

  defp merge_token_totals(nil, totals), do: totals

  defp merge_token_totals(left, right) when is_map(left) and is_map(right) do
    %{
      input_tokens: sum_token_field(left, right, :input_tokens),
      output_tokens: sum_token_field(left, right, :output_tokens),
      cached_tokens: sum_token_field(left, right, :cached_tokens),
      total_tokens: sum_token_field(left, right, :total_tokens)
    }
  end

  defp token_integer(tokens, keys) when is_map(tokens) and is_list(keys) do
    keys
    |> Enum.find_value(&Map.get(tokens, &1))
    |> case do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp token_integer(_tokens, _keys), do: 0

  defp sum_token_field(left, right, field) do
    Map.get(left, field, 0) + Map.get(right, field, 0)
  end

  defp cache_tokens(tokens) when is_map(tokens) do
    cached_total = token_integer(tokens, [:cached_tokens, "cached_tokens"])

    if cached_total > 0 do
      cached_total
    else
      token_integer(tokens, [:cache_read_tokens, "cache_read_tokens", :cached_input_tokens, "cached_input_tokens"]) +
        token_integer(tokens, [:cache_write_tokens, "cache_write_tokens"])
    end
  end

  defp cache_tokens(_tokens), do: 0

  defp normalize_token_totals(nil), do: %{input_tokens: 0, output_tokens: 0, cached_tokens: 0, total_tokens: 0}

  defp normalize_token_totals(totals) when is_map(totals) do
    %{
      input_tokens: Map.get(totals, :input_tokens, 0) || 0,
      output_tokens: Map.get(totals, :output_tokens, 0) || 0,
      cached_tokens: Map.get(totals, :cached_tokens, 0) || 0,
      total_tokens: Map.get(totals, :total_tokens, 0) || 0
    }
  end

  defp token_totals_zero?(totals) when is_map(totals) do
    Map.get(totals, :input_tokens, 0) == 0 and
      Map.get(totals, :output_tokens, 0) == 0 and
      Map.get(totals, :cached_tokens, 0) == 0 and
      Map.get(totals, :total_tokens, 0) == 0
  end

  defp provider_badge_class("codex"), do: "state-badge state-badge-active"
  defp provider_badge_class("openrouter"), do: "state-badge state-badge-warning"
  defp provider_badge_class("pi"), do: "state-badge state-badge-handoff"
  defp provider_badge_class("claude_code"), do: "state-badge state-badge-active"
  defp provider_badge_class("openai"), do: "state-badge state-badge-warning"
  defp provider_badge_class(provider) when is_binary(provider), do: "state-badge"
  defp provider_badge_class(_), do: "state-badge"
end
