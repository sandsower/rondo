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
            <p class="chart-card-title">Model usage</p>
            <div class="model-usage-grid">
              <div class="model-usage-item">
                <span class="model-usage-provider">Codex</span>
                <span class="model-usage-pct"><%= format_model_pct(@payload.model_usage.codex_pct) %></span>
                <span class="model-usage-detail"><%= model_usage_run_count(@payload.model_usage, "codex") %> runs</span>
              </div>
              <div class="model-usage-item">
                <span class="model-usage-provider">OpenRouter</span>
                <span class="model-usage-pct"><%= format_model_pct(@payload.model_usage.openrouter_pct) %></span>
                <span class="model-usage-detail"><%= model_usage_run_count(@payload.model_usage, "openrouter") %> runs</span>
              </div>
            </div>
            <%= if Map.get(@payload.model_usage, :by_provider) |> Map.keys() |> Enum.reject(&(&1 in ["codex", "openrouter"])) != [] do %>
              <div class="model-usage-others" style="margin-top: 8px;">
                <span class="muted" style="font-size: 11px;">
                  Other: <%= @payload.model_usage.by_provider |> Map.keys() |> Enum.reject(&(&1 in ["codex", "openrouter"])) |> Enum.map_join(", ", &("#{&1} #{format_model_pct(Map.get(@payload.model_usage.by_provider, &1).run_pct)}")) %>
                </span>
              </div>
            <% end %>
            <%= if Map.get(@payload.model_usage, :by_model) |> map_size() > 0 do %>
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
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"} onclick="event.stopPropagation()">JSON</a>
                      </div>
                    </td>
                    <td>
                      <span class={guidance_severity_class(entry.guidance_severity)}>
                        <%= entry.guidance_severity || "warning" %>
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
                    <td class="mono"><%= entry.paused_at || "n/a" %></td>
                    <td class="numeric"><%= length(entry.event_log || []) %> events</td>
                    <td>
                      <%= if quick_guidance_response(entry) do %>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="submit_guidance"
                          phx-value-issue-id={entry.issue_id}
                          phx-value-guidance={quick_guidance_response(entry).guidance || quick_guidance_response(entry).id}
                          onclick="event.stopPropagation()"
                        >
                          <%= quick_guidance_response(entry).label || quick_guidance_response(entry).id %>
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
                  <%= if quick_guidance_response(@selected_issue_data) do %>
                    <button
                      type="button"
                      class="subtle-button"
                      phx-click="submit_guidance"
                      phx-value-issue-id={@selected_issue_data[:issue_id]}
                      phx-value-guidance={quick_guidance_response(@selected_issue_data).guidance || quick_guidance_response(@selected_issue_data).id}
                    >
                      <%= quick_guidance_response(@selected_issue_data).label || quick_guidance_response(@selected_issue_data).id %>
                    </button>
                  <% end %>
                </div>
              </form>
            </div>
          <% end %>

          <div class="panel-stream-header">
            <span class="panel-metric-label">Event stream</span>
            <span class="muted" style="font-size: 11px;"><%= length(selected_event_log(@selected_issue_data)) %> events</span>
          </div>

          <%= if selected_event_log(@selected_issue_data) == [] do %>
            <p class="empty-state">Waiting for agent activity...</p>
          <% else %>
            <div class="event-stream" id="event-stream" phx-hook="ScrollBottom">
              <div :for={entry <- selected_event_log(@selected_issue_data)} class="event-row">
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
    [:needs_guidance, :paused, :running, :retrying]
    |> Enum.flat_map(&Map.get(payload, &1, []))
    |> Enum.find(&(&1.issue_identifier == identifier))
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
    |> Map.get(:suggested_responses, [])
    |> Enum.find(fn response -> Map.get(response, :quick) == true end)
  end

  defp guidance_waiting_label(entry) do
    Map.get(entry.blocked_side_effect || %{}, :label) ||
      entry
      |> get_in([:interrupt, :reason])
      |> humanize_interrupt_reason()
  end

  defp guidance_waiting_meta(entry) do
    Map.get(entry.blocked_side_effect || %{}, :action) ||
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

  defp paused_claim_status(%{blocks_dispatch: true} = entry) do
    reason = Map.get(entry, :blocked_dispatch_reason) || "paused_claim"
    stale = Map.get(entry, :stale_reason)
    revalidated = Map.get(entry, :revalidated_at)

    ["Blocks dispatch: #{reason}", stale && "stale: #{stale}", revalidated && "revalidated: #{revalidated}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp paused_claim_status(_entry), do: nil

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

  defp format_finished_at(nil), do: ""

  defp format_finished_at(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S")
      _ -> iso_string
    end
  end

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

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp format_model_pct(pct) when is_float(pct), do: "#{Float.round(pct, 1)}%"
  defp format_model_pct(pct) when is_number(pct), do: "#{pct}%"
  defp format_model_pct(_), do: "n/a"

  defp model_usage_run_count(usage, provider) do
    case Map.get(usage.by_provider, provider) do
      %{run_count: count} -> count
      _ -> 0
    end
  end

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
  defp provider_badge_class(_), do: "state-badge"
end
