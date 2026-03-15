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
          threshold: 100
        ],
        ignore_modules: [
          Rondo.Config,
          Rondo.Linear.Client,
          Rondo.SpecsCheck,
          Rondo.Orchestrator,
          Rondo.Orchestrator.State,
          Rondo.AgentRunner,
          Rondo.CLI,
          Rondo.Claude.CLI,
          Rondo.Claude.StreamParser,
          Rondo.StatusDashboard,
          Rondo.LogFile,
          Rondo.Workspace
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
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
