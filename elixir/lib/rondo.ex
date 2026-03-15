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

  @impl true
  def start(_type, _args) do
    :ok = Rondo.LogFile.configure()

    children = [
      {Phoenix.PubSub, name: Rondo.PubSub},
      {Task.Supervisor, name: Rondo.TaskSupervisor},
      Rondo.WorkflowStore,
      Rondo.Orchestrator,
      Rondo.HttpServer,
      Rondo.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: Rondo.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    Rondo.StatusDashboard.render_offline_status()
    :ok
  end
end
