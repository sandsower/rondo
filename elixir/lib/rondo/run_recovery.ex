defmodule Rondo.RunRecovery do
  @moduledoc """
  Reconciles durable running ledgers after the coupled run supervisor restarts.

  The caller must establish the quiescent boundary first: the TaskSupervisor
  that owned all workers has stopped, so no worker can still mutate a ledger.
  Every valid ledger still marked `running` is then terminalized before a new
  Orchestrator begins serving requests.
  """

  alias Rondo.Core.RunLocator
  alias Rondo.RunLedger

  @type result :: %{run_id: String.t(), status: :recovered | :unchanged}

  @doc "Reconciles every orphaned running ledger under the configured root."
  @spec reconcile(keyword()) :: {:ok, [result()]} | {:error, term()}
  def reconcile(opts \\ []) do
    if Keyword.get(opts, :worker_supervisor_quiescent, false) do
      reconcile_quiescent(opts)
    else
      {:error, :worker_supervisor_not_quiescent}
    end
  end

  defp reconcile_quiescent(opts) do
    locator_opts =
      opts
      |> Keyword.take([:workspace_root])
      |> Keyword.put(:strict, true)

    recover_fun = Keyword.get(opts, :recover_fun, &RunLedger.recover_orphaned_run/2)

    case RunLocator.list_durable_runs(locator_opts) do
      {:ok, runs} -> recover_running_runs(runs, recover_fun, opts)
      {:error, _reason} = error -> error
    end
  end

  defp recover_running_runs(runs, recover_fun, opts) do
    runs
    |> Enum.filter(&(Map.get(&1.manifest, "status") == "running"))
    |> Enum.reduce_while({:ok, []}, &recover_run(&1, &2, recover_fun, opts))
    |> reverse_results()
  end

  defp recover_run(located, {:ok, recovered}, recover_fun, opts) do
    case recover_located_run(located, recover_fun, opts) do
      {:ok, result} ->
        {:cont, {:ok, [result | recovered]}}

      {:error, reason} ->
        {:halt, {:error, {:run_recovery_failed, located.run_dir, reason}}}
    end
  end

  defp recover_located_run(located, recover_fun, opts) do
    recovery_opts =
      opts
      |> Keyword.take([:timestamp])
      |> Keyword.put(:worker_supervisor_quiescent, true)

    with {:ok, ledger} <- RunLedger.open_run(located.run_dir),
         {:ok, recovered, status} <- recover_fun.(ledger, recovery_opts) do
      {:ok, %{run_id: recovered.run_id, status: status}}
    end
  end

  defp reverse_results({:ok, results}), do: {:ok, Enum.reverse(results)}
  defp reverse_results(error), do: error
end
