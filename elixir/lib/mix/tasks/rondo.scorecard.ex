defmodule Mix.Tasks.Rondo.Scorecard do
  use Mix.Task

  alias Rondo.RunScorecard

  @moduledoc """
  Prints a ledger-derived cross-run outcome scorecard.

  ## Usage

      mix rondo.scorecard [--workspace-root PATH] [--json]

  Walks `.rondo_runs/*/*/manifest.json` (plus linked clean-eval and gate
  result artifacts) under the workspace root and prints an aggregate
  scorecard covering clean-eval outcomes, per-gate pass rates, per-adapter run
  counts, final-report validity, and escalation counts. This is read-only: it
  never mutates the ledger and never runs anything.

  `--workspace-root` defaults to the configured `Rondo.Config.workspace_root/0`.
  `--json` prints the machine-readable form instead of the text summary.
  """
  @shortdoc "Prints a ledger-derived cross-run outcome scorecard"

  @switches [workspace_root: :string, json: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)

    scorecard = RunScorecard.build(scorecard_opts(opts))

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(RunScorecard.to_json(scorecard))
    else
      Mix.shell().info(format_text(scorecard))
    end
  end

  defp scorecard_opts(opts) do
    case Keyword.get(opts, :workspace_root) do
      nil -> []
      root -> [workspace_root: root]
    end
  end

  defp format_text(scorecard) do
    [
      "Rondo run scorecard - #{scorecard.generated_at}",
      "workspace_root: #{scorecard.workspace_root}",
      "runs_total: #{scorecard.runs_total} (skipped_unreadable: #{scorecard.runs_skipped_unreadable})",
      "",
      "clean_eval:",
      format_clean_eval(scorecard.clean_eval),
      "",
      "gates:",
      format_gates(scorecard.gates),
      "",
      "adapters:",
      format_adapters(scorecard.adapters),
      "",
      "final_report:",
      format_final_report(scorecard.final_report),
      "",
      "escalations: #{scorecard.escalations}"
    ]
    |> Enum.join("\n")
  end

  defp format_clean_eval(clean_eval) do
    "  pass=#{clean_eval.pass} fail=#{clean_eval.fail} error=#{clean_eval.error} skipped=#{clean_eval.skipped} rate=#{clean_eval.rate}"
  end

  defp format_gates([]), do: "  (none)"

  defp format_gates(gates) do
    Enum.map_join(gates, "\n", fn gate ->
      "  #{gate.name}: pass=#{gate.pass} fail=#{gate.fail} error=#{gate.error} timeout=#{gate.timeout} rate=#{gate.rate}"
    end)
  end

  defp format_adapters([]), do: "  (none)"

  defp format_adapters(adapters) do
    Enum.map_join(adapters, "\n", fn adapter ->
      "  #{adapter.name}: runs=#{adapter.runs} completed=#{adapter.completed} failed=#{adapter.failed}"
    end)
  end

  defp format_final_report(final_report) do
    "  valid=#{final_report.valid} invalid=#{final_report.invalid} missing=#{final_report.missing}"
  end
end
