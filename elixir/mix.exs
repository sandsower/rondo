defmodule Rondo.MixProject do
  use Mix.Project

  def project do
    [
      app: :rondo,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          # Ratchet: this number may only increase. Raising coverage is
          # welcome; lowering the threshold requires a ticket.
          threshold: 81
        ],
        ignore_modules: [
          # Display-only surfaces, excluded deliberately: the whole web
          # layer (LiveView/Phoenix rendering, routing, and Phoenix's own
          # generated Router.Helpers module), plus the two dashboard/
          # timeseries display modules. None of these are part of the
          # execution core the coverage gate is meant to protect.
          RondoWeb.ArchivedRuns,
          RondoWeb.ArchivedRuns.Sorter,
          RondoWeb.DashboardEventStream,
          RondoWeb.DashboardLive,
          RondoWeb.Endpoint,
          RondoWeb.ErrorHTML,
          RondoWeb.ErrorJSON,
          RondoWeb.EventInspector,
          RondoWeb.Layouts,
          RondoWeb.ObservabilityApiController,
          RondoWeb.ObservabilityPubSub,
          RondoWeb.Presenter,
          RondoWeb.PresenterCache,
          RondoWeb.ResultSummary,
          RondoWeb.Router,
          RondoWeb.Router.Helpers,
          RondoWeb.StaticAssetController,
          RondoWeb.StaticAssets,
          Rondo.StatusDashboard,
          Rondo.TimeSeries
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs",
        "test/support/live_e2e.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Rondo.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:nimble_options, "~> 1.1"},
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.3"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: Rondo.CLI,
      name: "rondo",
      path: "bin/rondo"
    ]
  end
end
