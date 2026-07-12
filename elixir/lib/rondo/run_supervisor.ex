defmodule Rondo.RunSupervisor do
  @moduledoc """
  Couples the Orchestrator to every task it owns.

  The one-for-all boundary guarantees that an Orchestrator crash stops the
  TaskSupervisor and all workers before the replacement Orchestrator performs
  durable startup reconciliation.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, Rondo.TaskSupervisor)
    orchestrator = Keyword.get(opts, :orchestrator, Rondo.Orchestrator)
    service_mode = Keyword.get(opts, :service_mode, :tracker_daemon)

    orchestrator_opts =
      opts
      |> Keyword.get(:orchestrator_opts, [])
      |> Keyword.put(:name, orchestrator)
      |> Keyword.put(:task_supervisor, task_supervisor)
      |> Keyword.put(:run_recovery, true)
      |> Keyword.put(:service_mode, service_mode)
      |> Keyword.put(:tracker_polling, service_mode != :trackerless_core)

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor},
        id: task_supervisor
      ),
      Supervisor.child_spec(
        {Rondo.Orchestrator, orchestrator_opts},
        id: orchestrator
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
