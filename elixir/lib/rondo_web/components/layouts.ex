defmodule RondoWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @css_path Path.join([__DIR__, "..", "..", "..", "priv", "static", "dashboard.css"]) |> Path.expand()
  @external_resource @css_path

  @css_version (case File.read(@css_path) do
                  {:ok, content} -> content |> :erlang.md5() |> Base.encode16(case: :lower) |> binary_part(0, 8)
                  {:error, _} -> "0"
                end)

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:css_version, @css_version)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Rondo Observability</title>
        <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%234f6ef7'/%3E%3Ccircle cx='16' cy='16' r='6' fill='none' stroke='white' stroke-width='3'/%3E%3C/svg%3E" />
        <script>
          // Dark mode: blocking script to prevent FOUC — runs before stylesheet
          (function() {
            try {
              var saved = localStorage.getItem('rondo-theme');
              if (saved === 'dark' || saved === 'light') {
                document.documentElement.setAttribute('data-theme', saved);
              } else if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
                document.documentElement.setAttribute('data-theme', 'dark');
              }
            } catch(e) {}
          })();
        </script>
        <link rel="stylesheet" href={"/dashboard.css?v=#{@css_version}"} />
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script defer src="/vendor/chart.js/chart.min.js"></script>
        <script>
          // Theme helpers
          window.RondoTheme = {
            toggle: function() {
              var current = document.documentElement.getAttribute('data-theme');
              var next = (current === 'dark') ? 'light' : 'dark';
              document.body.classList.add('theme-transitioning');
              document.documentElement.setAttribute('data-theme', next);
              try { localStorage.setItem('rondo-theme', next); } catch(e) {}
              document.dispatchEvent(new CustomEvent('rondo:theme-changed', {detail: {theme: next}}));
              setTimeout(function() { document.body.classList.remove('theme-transitioning'); }, 400);
            },
            current: function() {
              return document.documentElement.getAttribute('data-theme') || 'light';
            },
            colors: function() {
              var s = getComputedStyle(document.documentElement);
              return {
                text: s.getPropertyValue('--text-secondary').trim(),
                textMuted: s.getPropertyValue('--text-muted').trim(),
                border: s.getPropertyValue('--border-subtle').trim(),
                surface: s.getPropertyValue('--surface-1').trim(),
                accent: s.getPropertyValue('--accent').trim(),
                success: s.getPropertyValue('--success').trim(),
                warning: s.getPropertyValue('--warning').trim(),
                danger: s.getPropertyValue('--danger').trim()
              };
            }
          };

          // System preference listener (only when no manual choice)
          if (window.matchMedia) {
            window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(e) {
              try {
                if (!localStorage.getItem('rondo-theme')) {
                  document.documentElement.setAttribute('data-theme', e.matches ? 'dark' : 'light');
                  document.dispatchEvent(new CustomEvent('rondo:theme-changed'));
                }
              } catch(ex) {}
            });
          }

          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            // --- Chart helper ---
            function applyChartTheme(chart) {
              if (!chart) return;
              var c = RondoTheme.colors();
              var scales = chart.options.scales || {};
              Object.values(scales).forEach(function(s) {
                if (s.ticks) s.ticks.color = c.text;
                if (s.grid) s.grid.color = c.border;
              });
              if (chart.options.plugins && chart.options.plugins.legend) {
                chart.options.plugins.legend.labels.color = c.text;
              }
              chart.update('none');
            }

            function baseChartOpts(type) {
              var c = RondoTheme.colors();
              return {
                responsive: true,
                maintainAspectRatio: false,
                animation: { duration: 300 },
                plugins: {
                  legend: { labels: { color: c.text, boxWidth: 12, padding: 8, font: { size: 11 } } },
                  tooltip: { titleFont: { size: 11 }, bodyFont: { size: 11 }, padding: 6 }
                },
                scales: type === 'bar-horizontal' ? {
                  x: { ticks: { color: c.text, font: { size: 10 } }, grid: { color: c.border } },
                  y: { ticks: { color: c.text, font: { size: 10 } }, grid: { display: false } }
                } : {
                  x: { ticks: { color: c.text, font: { size: 10 }, maxTicksLimit: 12 }, grid: { color: c.border } },
                  y: { ticks: { color: c.text, font: { size: 10 } }, grid: { color: c.border }, beginAtZero: true }
                }
              };
            }

            // --- Hooks ---
            var Hooks = {};

            Hooks.ThemeToggle = {
              mounted() {
                this.update();
                this._handler = () => this.update();
                document.addEventListener('rondo:theme-changed', this._handler);
              },
              update() {
                var isDark = RondoTheme.current() === 'dark';
                var cb = this.el.querySelector('input[type="checkbox"]');
                if (cb) cb.checked = isDark;
              },
              destroyed() { document.removeEventListener('rondo:theme-changed', this._handler); }
            };

            Hooks.CopyButton = {
              mounted() {
                this._label = this.el.dataset.label || this.el.textContent;
                this._onClick = async (e) => {
                  e.stopPropagation();
                  var text = this.el.dataset.copy || '';

                  try {
                    await navigator.clipboard.writeText(text);
                    this.el.textContent = 'Copied';
                    clearTimeout(this._timer);
                    this._timer = setTimeout(() => { this.el.textContent = this._label; }, 1200);
                  } catch (_err) {
                    this.el.textContent = this._label;
                  }
                };
                this.el.addEventListener('click', this._onClick);
              },
              destroyed() {
                clearTimeout(this._timer);
                this.el.removeEventListener('click', this._onClick);
              }
            };

            Hooks.ScrollBottom = {
              mounted() { this.scrollToBottom(); },
              updated() { this.scrollToBottom(); },
              scrollToBottom() { this.el.scrollTop = this.el.scrollHeight; }
            };

            Hooks.TokenChart = {
              mounted() {
                var ctx = this.el.getContext('2d');
                var c = RondoTheme.colors();
                this.chart = new Chart(ctx, {
                  type: 'line',
                  data: { labels: [], datasets: [
                    { label: 'Input', data: [], borderColor: c.accent, backgroundColor: c.accent + '20', fill: true, tension: 0.3, pointRadius: 0 },
                    { label: 'Output', data: [], borderColor: c.success, backgroundColor: c.success + '20', fill: true, tension: 0.3, pointRadius: 0 }
                  ]},
                  options: baseChartOpts('line')
                });
                this.handleEvent("update-token-chart", (payload) => {
                  this.chart.data.labels = payload.labels;
                  this.chart.data.datasets[0].data = payload.input;
                  this.chart.data.datasets[1].data = payload.output;
                  this.chart.update('none');
                });
                this._themeHandler = () => applyChartTheme(this.chart);
                document.addEventListener('rondo:theme-changed', this._themeHandler);
              },
              destroyed() {
                document.removeEventListener('rondo:theme-changed', this._themeHandler);
                if (this.chart) this.chart.destroy();
              }
            };

            Hooks.SessionChart = {
              mounted() {
                var ctx = this.el.getContext('2d');
                var c = RondoTheme.colors();
                this.chart = new Chart(ctx, {
                  type: 'line',
                  data: { labels: [], datasets: [
                    { label: 'Running', data: [], borderColor: c.success, backgroundColor: c.success + '30', fill: true, tension: 0.3, pointRadius: 0 },
                    { label: 'Retrying', data: [], borderColor: c.warning, backgroundColor: c.warning + '30', fill: true, tension: 0.3, pointRadius: 0 }
                  ]},
                  options: baseChartOpts('line')
                });
                this.handleEvent("update-session-chart", (payload) => {
                  this.chart.data.labels = payload.labels;
                  this.chart.data.datasets[0].data = payload.running;
                  this.chart.data.datasets[1].data = payload.retrying;
                  this.chart.update('none');
                });
                this._themeHandler = () => applyChartTheme(this.chart);
                document.addEventListener('rondo:theme-changed', this._themeHandler);
              },
              destroyed() {
                document.removeEventListener('rondo:theme-changed', this._themeHandler);
                if (this.chart) this.chart.destroy();
              }
            };

            Hooks.OutcomeChart = {
              mounted() {
                var self = this;
                var ctx = this.el.getContext('2d');
                var c = RondoTheme.colors();
                this.chart = new Chart(ctx, {
                  type: 'bar',
                  data: { labels: [], datasets: [
                    { label: 'Tokens', data: [], backgroundColor: c.accent + 'aa', borderRadius: 4 }
                  ]},
                  options: Object.assign(baseChartOpts('bar-horizontal'), {
                    indexAxis: 'y',
                    onClick: function(evt, elements) {
                      if (elements.length > 0) {
                        var idx = elements[0].index;
                        var identifier = self.chart.data.labels[idx];
                        if (identifier) self.pushEvent("select_archived", {identifier: identifier});
                      }
                    }
                  })
                });
                this.handleEvent("update-outcome-chart", (payload) => {
                  this.chart.data.labels = payload.labels;
                  this.chart.data.datasets[0].data = payload.values;
                  var c = RondoTheme.colors();
                  this.chart.data.datasets[0].backgroundColor = payload.colors.map(function(t) {
                    if (t === 'success' || t === 'merged_done') return c.success + 'aa';
                    if (t === 'review_handoff') return c.accent + 'aa';
                    if (t === 'blocked_paused') return c.warning + 'aa';
                    if (t === 'canceled') return c.textMuted + 'aa';
                    if (t === 'failed' || t === 'terminated') return c.danger + 'aa';
                    if (t === 'completed') return c.success + 'aa';
                    if (t === 'handed_off') return c.accent + 'aa';
                    return c.danger + 'aa';
                  });
                  this.chart.update('none');
                });
                this._themeHandler = () => applyChartTheme(this.chart);
                document.addEventListener('rondo:theme-changed', this._themeHandler);
              },
              destroyed() {
                document.removeEventListener('rondo:theme-changed', this._themeHandler);
                if (this.chart) this.chart.destroy();
              }
            };

            Hooks.RunTokenChart = {
              mounted() {
                var self = this;
                var ctx = this.el.getContext('2d');
                var c = RondoTheme.colors();
                this.chart = new Chart(ctx, {
                  type: 'bar',
                  data: { labels: [], datasets: [
                    { label: 'Input', data: [], backgroundColor: c.accent + 'aa', borderRadius: 3 },
                    { label: 'Output', data: [], backgroundColor: c.success + 'aa', borderRadius: 3 }
                  ]},
                  options: Object.assign(baseChartOpts('bar'), {
                    onClick: function(evt, elements) {
                      if (elements.length > 0) {
                        self.pushEvent("select_run", {index: String(elements[0].index)});
                      }
                    }
                  })
                });
                this.handleEvent("update-run-token-chart", (payload) => {
                  this.chart.data.labels = payload.labels;
                  this.chart.data.datasets[0].data = payload.input;
                  this.chart.data.datasets[1].data = payload.output;
                  this.chart.update('none');
                });
                this._themeHandler = () => applyChartTheme(this.chart);
                document.addEventListener('rondo:theme-changed', this._themeHandler);
              },
              destroyed() {
                document.removeEventListener('rondo:theme-changed', this._themeHandler);
                if (this.chart) this.chart.destroy();
              }
            };

            Hooks.RunDurationChart = {
              mounted() {
                var self = this;
                var ctx = this.el.getContext('2d');
                var c = RondoTheme.colors();
                this.chart = new Chart(ctx, {
                  type: 'bar',
                  data: { labels: [], datasets: [
                    { label: 'Duration (s)', data: [], backgroundColor: c.accent + 'aa', borderRadius: 3 }
                  ]},
                  options: Object.assign(baseChartOpts('bar'), {
                    onClick: function(evt, elements) {
                      if (elements.length > 0) {
                        self.pushEvent("select_run", {index: String(elements[0].index)});
                      }
                    }
                  })
                });
                this.handleEvent("update-run-duration-chart", (payload) => {
                  this.chart.data.labels = payload.labels;
                  this.chart.data.datasets[0].data = payload.durations;
                  this.chart.update('none');
                });
                this._themeHandler = () => applyChartTheme(this.chart);
                document.addEventListener('rondo:theme-changed', this._themeHandler);
              },
              destroyed() {
                document.removeEventListener('rondo:theme-changed', this._themeHandler);
                if (this.chart) this.chart.destroy();
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: Hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <header class="top-nav">
      <div class="top-nav-inner">
        <span class="top-nav-brand">
          Rondo <span class="top-nav-brand-suffix">Observability</span>
        </span>
        <nav class="top-nav-links" aria-label="Dashboard sections">
          <a class="top-nav-link" href="#logs">Logs</a>
          <a class="top-nav-link" href="#guidance">Guidance</a>
          <a class="top-nav-link" href="#sessions">Sessions</a>
          <a class="top-nav-link" href="#retries">Retries</a>
          <a class="top-nav-link" href="#archived">Archive</a>
        </nav>
        <div class="top-nav-status">
          <span class="status-badge status-badge-live">
            <span class="status-badge-dot"></span>
            Live
          </span>
          <label class="theme-switch" id="theme-toggle" phx-hook="ThemeToggle" phx-update="ignore">
            <input type="checkbox" aria-label="Toggle dark mode" onclick="RondoTheme.toggle()" />
            <span class="theme-switch-track">
              <svg class="theme-icon-sun" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" aria-hidden="true"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>
              <svg class="theme-icon-moon" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" aria-hidden="true"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>
            </span>
          </label>
        </div>
      </div>
    </header>
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
