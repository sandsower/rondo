defmodule RondoWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @css_version (
    path = Path.join([__DIR__, "..", "..", "..", "priv", "static", "dashboard.css"]) |> Path.expand()
    case File.read(path) do
      {:ok, content} -> content |> :erlang.md5() |> Base.encode16(case: :lower) |> binary_part(0, 8)
      {:error, _} -> "0"
    end
  )

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
                    return t === 'completed' ? c.success + 'aa' : c.danger + 'aa';
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
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
