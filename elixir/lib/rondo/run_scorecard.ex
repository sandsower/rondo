defmodule Rondo.RunScorecard do
  @moduledoc """
  Ledger-derived, read-only outcome scorecard aggregated across every run
  recorded under a workspace root's `.rondo_runs/` tree.

  This is retroactive reporting: it walks whatever ledgers already exist on
  disk (`manifest.json`, gate `results.json` artifacts, and
  `clean_eval/result.json`) and aggregates outcomes. It never runs anything and
  never writes to the ledger. It is unrelated to `Rondo.Telemetry`, which
  instruments live events as runs happen; this module only looks backward at
  what has already been persisted.

  ## Tolerance

  Manifests are loaded with `Rondo.RunLedger.load_manifest/1`, which already
  validates schema shape. A run directory whose manifest is missing, invalid
  JSON, or fails shape validation (including older/incompatible schema
  versions) is skipped and counted in `runs_skipped_unreadable` - it never
  raises. Missing or unreadable per-run artifacts (clean-eval result, gate
  results) are treated the same way at the metric level: they simply do not
  contribute to that metric's counts, without affecting `runs_skipped_unreadable`,
  since the manifest itself was readable.

  ## Aggregation rules

  - `clean_eval` - one bucket per run, read from the run's
    `clean_eval/result.json` (`Rondo.CleanEval.result_relative_path/0`). Runs
    with no such file (clean eval disabled or not yet run) do not contribute.
  - `gates` - per gate name, aggregated across every `"gate_results"` artifact
    linked in each manifest's `"artifacts"` list. A `:reused` gate status (a
    cache hit on a previously passing gate) is folded into `pass`. Statuses
    outside `pass/reused/fail/error/timeout` (e.g. policy-blocked) are counted
    in neither numerator nor denominator.
  - `adapters` - per `manifest["agent"]["adapter"]`, counting total runs plus
    how many reached `"completed"` / `"failed"` ledger status.
  - `final_report` - per `manifest["final_report"]["status"]`
    (`"valid"`/`"invalid"`/`"missing"`); runs where no final-report validation
    was ever recorded (e.g. still running, or crashed earlier) do not
    contribute.
  - `escalations` - the number of attempt-chain entries with
    `"reason" => "escalation"` found in `manifest["escalation"]["attempt_chain"]`.
    That field is only persisted onto the manifest of the run where an
    escalation chain paused (see `Rondo.Escalation`), so each chain is counted
    exactly once, from its terminal run.
  """

  require Logger

  alias Rondo.{CleanEval, Config, RunLedger}
  alias Rondo.RunEvidence.ArtifactCatalog

  @type clean_eval_summary :: %{
          pass: non_neg_integer(),
          fail: non_neg_integer(),
          error: non_neg_integer(),
          skipped: non_neg_integer(),
          rate: float()
        }

  @type gate_summary :: %{
          name: String.t(),
          pass: non_neg_integer(),
          fail: non_neg_integer(),
          error: non_neg_integer(),
          timeout: non_neg_integer(),
          rate: float()
        }

  @type adapter_summary :: %{
          name: String.t(),
          runs: non_neg_integer(),
          completed: non_neg_integer(),
          failed: non_neg_integer()
        }

  @type final_report_summary :: %{
          valid: non_neg_integer(),
          invalid: non_neg_integer(),
          missing: non_neg_integer()
        }

  @type t :: %{
          generated_at: String.t(),
          workspace_root: String.t(),
          runs_total: non_neg_integer(),
          runs_skipped_unreadable: non_neg_integer(),
          clean_eval: clean_eval_summary(),
          gates: [gate_summary()],
          adapters: [adapter_summary()],
          final_report: final_report_summary(),
          escalations: non_neg_integer()
        }

  @doc """
  Builds the scorecard for a workspace root.

  Options:

  - `:workspace_root` - defaults to `Rondo.Config.workspace_root/0`.
  - `:now` - timestamp override for `generated_at`, defaults to
    `DateTime.utc_now/0`.
  """
  @spec build(keyword()) :: t()
  def build(opts \\ []) do
    workspace_root = opts |> Keyword.get(:workspace_root, Config.workspace_root()) |> Path.expand()
    now = Keyword.get(opts, :now, DateTime.utc_now())

    manifest_paths = discover_manifest_paths(workspace_root)
    {runs, skipped} = load_runs(manifest_paths)

    %{
      generated_at: datetime_to_iso(now),
      workspace_root: workspace_root,
      runs_total: length(manifest_paths),
      runs_skipped_unreadable: skipped,
      clean_eval: clean_eval_summary(runs),
      gates: gates_summary(runs),
      adapters: adapters_summary(runs),
      final_report: final_report_summary(runs),
      escalations: escalations_count(runs)
    }
  end

  @doc "Encodes a built scorecard as JSON."
  @spec to_json(t()) :: String.t()
  def to_json(scorecard) when is_map(scorecard) do
    Jason.encode!(scorecard)
  end

  defp discover_manifest_paths(workspace_root) do
    Path.wildcard(Path.join([workspace_root, ".rondo_runs", "*", "*", "manifest.json"]))
  end

  defp load_runs(manifest_paths) do
    {runs, skipped} =
      Enum.reduce(manifest_paths, {[], 0}, fn manifest_path, {acc, skipped} ->
        case RunLedger.load_manifest(manifest_path) do
          {:ok, manifest} ->
            {[{manifest, Path.dirname(manifest_path)} | acc], skipped}

          {:error, reason} ->
            Logger.warning("rondo.scorecard: skipping unreadable ledger manifest=#{manifest_path} reason=#{inspect(reason)}")
            {acc, skipped + 1}
        end
      end)

    {Enum.reverse(runs), skipped}
  end

  defp clean_eval_summary(runs) do
    counts =
      runs
      |> Enum.map(&clean_eval_status/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    pass = Map.get(counts, "pass", 0)
    fail = Map.get(counts, "fail", 0)
    error = Map.get(counts, "error", 0)
    skipped = Map.get(counts, "skipped", 0)

    %{pass: pass, fail: fail, error: error, skipped: skipped, rate: rate(pass, pass + fail + error + skipped)}
  end

  defp clean_eval_status({_manifest, run_dir}) do
    path = Path.join(run_dir, CleanEval.result_relative_path())

    with true <- File.regular?(path),
         {:ok, json} <- File.read(path),
         {:ok, %{"status" => status}} when status in ["pass", "fail", "error", "skipped"] <- Jason.decode(json) do
      status
    else
      _other -> nil
    end
  end

  defp gates_summary(runs) do
    runs
    |> Enum.flat_map(&gate_results_for_run/1)
    |> Enum.reject(&(is_nil(&1.name) or is_nil(&1.status)))
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, results} -> gate_row(name, results) end)
    |> Enum.sort_by(& &1.name)
  end

  defp gate_row(name, results) do
    counts = Enum.frequencies_by(results, & &1.status)
    pass = Map.get(counts, :pass, 0) + Map.get(counts, :reused, 0)
    fail = Map.get(counts, :fail, 0)
    error = Map.get(counts, :error, 0)
    timeout = Map.get(counts, :timeout, 0)

    total = pass + fail + error + timeout
    %{name: name, pass: pass, fail: fail, error: error, timeout: timeout, rate: rate(pass, total)}
  end

  defp gate_results_for_run({manifest, run_dir}) do
    manifest
    |> Map.get("artifacts", [])
    |> ArtifactCatalog.find_all("gate_results")
    |> Enum.flat_map(&load_gate_results(&1, run_dir))
  end

  defp load_gate_results(%{"path" => path}, run_dir) when is_binary(path) do
    full_path = Path.join(run_dir, path)

    with true <- File.regular?(full_path),
         {:ok, json} <- File.read(full_path),
         {:ok, %{"results" => results}} when is_list(results) <- Jason.decode(json) do
      Enum.map(results, &normalize_gate_result/1)
    else
      _other -> []
    end
  end

  defp load_gate_results(_artifact, _run_dir), do: []

  defp normalize_gate_result(%{"name" => name, "status" => status}) when is_binary(name) and is_binary(status) do
    %{name: name, status: gate_status_atom(status)}
  end

  defp normalize_gate_result(_result), do: %{name: nil, status: nil}

  defp gate_status_atom("pass"), do: :pass
  defp gate_status_atom("reused"), do: :reused
  defp gate_status_atom("fail"), do: :fail
  defp gate_status_atom("error"), do: :error
  defp gate_status_atom("timeout"), do: :timeout
  defp gate_status_atom(_other), do: :other

  defp adapters_summary(runs) do
    runs
    |> Enum.map(fn {manifest, _run_dir} -> get_in(manifest, ["agent", "adapter"]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&adapter_row(&1, runs))
  end

  defp adapter_row(name, runs) do
    matching = Enum.filter(runs, fn {manifest, _run_dir} -> get_in(manifest, ["agent", "adapter"]) == name end)

    %{
      name: name,
      runs: length(matching),
      completed: Enum.count(matching, fn {manifest, _run_dir} -> Map.get(manifest, "status") == "completed" end),
      failed: Enum.count(matching, fn {manifest, _run_dir} -> Map.get(manifest, "status") == "failed" end)
    }
  end

  defp final_report_summary(runs) do
    counts =
      runs
      |> Enum.map(fn {manifest, _run_dir} -> get_in(manifest, ["final_report", "status"]) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    %{
      valid: Map.get(counts, "valid", 0),
      invalid: Map.get(counts, "invalid", 0),
      missing: Map.get(counts, "missing", 0)
    }
  end

  defp escalations_count(runs) do
    runs
    |> Enum.map(fn {manifest, _run_dir} -> get_in(manifest, ["escalation", "attempt_chain"]) end)
    |> Enum.filter(&is_list/1)
    |> Enum.map(fn chain -> Enum.count(chain, &(Map.get(&1, "reason") == "escalation")) end)
    |> Enum.sum()
  end

  defp rate(_pass, 0), do: 0.0
  defp rate(pass, total), do: Float.round(pass / total, 4)

  defp datetime_to_iso(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
