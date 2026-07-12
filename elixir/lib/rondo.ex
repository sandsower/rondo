defmodule Rondo do
  @moduledoc """
  Entry point for the Rondo orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Rondo.Orchestrator.start_link(opts)
  end
end

defmodule Rondo.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias Rondo.Config
  alias Rondo.Core.Identity
  alias Rondo.StatusDashboard

  @impl true
  def start(_type, _args) do
    :ok = Rondo.LogFile.configure()
    :ok = Identity.initialize()

    children = children(Config.service_mode())

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: Rondo.Supervisor
    )
  end

  defp children(:trackerless_core) do
    [
      {Phoenix.PubSub, name: Rondo.PubSub},
      {Rondo.RunSupervisor, service_mode: :trackerless_core},
      Rondo.HttpServer
    ]
  end

  defp children(:tracker_daemon) do
    [
      {Phoenix.PubSub, name: Rondo.PubSub},
      RondoWeb.PresenterCache,
      Rondo.WorkflowStore,
      {Rondo.RunSupervisor, service_mode: :tracker_daemon},
      Rondo.HttpServer,
      Rondo.StatusDashboard
    ]
  end

  @impl true
  def stop(_state) do
    if Config.service_mode() == :tracker_daemon do
      StatusDashboard.render_offline_status()
    end

    :ok
  end
end
