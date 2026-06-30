defmodule Rondo.CleanEval do
  @moduledoc """
  Clean-room evaluation of a run's patch artifact, separate from the agent workspace.

  Consumes the `rondo.patch/v0` patch artifact contract (`artifacts/changes.patch` +
  `artifacts/patch.json` inside the run ledger dir), creates a detached clean git
  worktree of the recorded base ref under
  `<workspace_root>/.rondo_clean_eval/<run_id>`, applies the patch, runs evaluator
  gates there, and always removes the worktree afterwards.

  Outcomes are recorded in the run ledger, never raised:

  - `clean_eval/result.json` — `rondo.clean_eval/v0` result artifact with final
    status, base ref, patch apply outcome, gate summary, and cleanup details.
  - gate logs/results under `clean_eval/gates/` (separate from agent `artifacts/`).
  - a `clean_eval_completed` checkpoint and a manifest `"clean_eval"` block
    reporting pass/fail.

  Patch apply failures are evaluator failures (`:fail`), not crashes. A missing
  patch artifact (run with no changes) yields `:skipped`. Infrastructure problems
  (missing workspace, worktree creation failure, unreadable metadata) yield `:error`.
  Gate timeouts are classified as environment failures (`:error`, not `:fail`),
  consistent with `Rondo.Gates`' retryable/environment-failure classification.

  The gate runner is an injectable seam (`:gate_runner`, defaulting to
  `Rondo.Gates.run/3` — `(gates, workspace, opts) -> {:ok, summary} | {:error,
  summary | term}`). By default clean evaluation asks the configured
  `Rondo.ProcessProvider` for the pre-PR gate selection and runs those gates in
  the clean worktree. An explicit `:gates` option remains available for tests and
  low-level callers that need to exercise only the clean worktree mechanics.
  """

  require Logger

  alias Rondo.{Config, Gates, ProcessProvider, RunLedger}
  alias Rondo.ProcessProvider.{Beislid, Native}

  @schema "rondo.clean_eval/v0"
  @patch_relative_path "artifacts/changes.patch"
  @patch_metadata_relative_path "artifacts/patch.json"
  @result_relative_path "clean_eval/result.json"
  @gates_relative_dir "clean_eval/gates"
  @eval_root_dirname ".rondo_clean_eval"
  @max_apply_output_bytes 16_384

  @type status :: :pass | :fail | :error | :skipped
  @type result :: %{required(:status) => status(), optional(atom()) => term()}
  @type runner :: ([String.t()], Path.t() -> {String.t(), non_neg_integer()})

  @doc "Returns the clean-eval result schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Returns the run-dir-relative path of the clean-eval result artifact."
  @spec result_relative_path() :: String.t()
  def result_relative_path, do: @result_relative_path

  @doc "Whether clean evaluation is enabled via the `clean_eval.enabled` config."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.clean_eval_enabled?()

  @doc """
  Runs clean evaluation for the given run ledger.

  Options:

  - `:base_ref` — overrides the configured/recorded base ref.
  - `:gates` — overrides configured evaluator gates (`clean_eval.gates`, falling
    back to top-level `gates`).
  - `:gate_runner` — gate runner seam, defaults to `Rondo.Gates.run/3`.
  - `:runner` — git runner for tests, `fn args, cd -> {output, exit_status} end`.
  - `:workspace` — overrides the manifest `repo.workspace` source repo path.
  - `:now` — timestamp override.

  Returns `{:ok, ledger, result}` with the recorded evaluation result, or
  `{:error, term}` only when persisting the result into the ledger fails.
  """
  @spec run(RunLedger.t(), keyword()) :: {:ok, RunLedger.t(), result()} | {:error, term()}
  def run(%RunLedger{} = ledger, opts \\ []) do
    started_at = Keyword.get(opts, :now, DateTime.utc_now())
    context = build_context(ledger, opts)
    result = evaluate(context)
    persist(ledger, result, started_at)
  end

  defp build_context(ledger, opts) do
    workspace_root = get_in(ledger.manifest, ["repo", "workspace_root"])

    %{
      run_dir: ledger.run_dir,
      workspace: Keyword.get(opts, :workspace, get_in(ledger.manifest, ["repo", "workspace"])),
      eval_workspace: eval_workspace_path(workspace_root, ledger.run_id),
      base_ref_override: Keyword.get(opts, :base_ref, Config.clean_eval_base_ref()),
      gates_override: gates_override(opts),
      process_provider: process_provider(ledger, opts),
      source_contract: Keyword.get(opts, :source_contract, Map.get(ledger.manifest, "source_contract")),
      gate_runner: Keyword.get(opts, :gate_runner, &Gates.run/3),
      runner: Keyword.get(opts, :runner, &run_git/2)
    }
  end

  defp eval_workspace_path(workspace_root, run_id) when is_binary(workspace_root) do
    Path.join([workspace_root, @eval_root_dirname, run_id])
  end

  defp eval_workspace_path(_workspace_root, _run_id), do: nil

  defp evaluate(context) do
    case load_patch(context) do
      {:ok, patch} ->
        context |> evaluate_patch(patch) |> Map.merge(patch_fields(patch))

      {:skipped, reason} ->
        %{status: :skipped, reason: reason}

      {:error, reason} ->
        %{status: :error, reason: reason}
    end
  end

  defp load_patch(context) do
    patch_path = Path.join(context.run_dir, @patch_relative_path)

    cond do
      !File.regular?(patch_path) -> {:skipped, "missing_patch_artifact"}
      is_nil(context.eval_workspace) -> {:error, "missing_workspace_root"}
      !is_binary(context.workspace) or !workspace_accessible?(context) -> {:error, "missing_workspace"}
      true -> load_patch_metadata(context, patch_path)
    end
  end

  defp load_patch_metadata(context, patch_path) do
    metadata_path = Path.join(context.run_dir, @patch_metadata_relative_path)

    with {:ok, json} <- read_metadata(metadata_path),
         {:ok, metadata} <- decode_metadata(json) do
      resolve_base_ref(context, patch_path, metadata)
    end
  end

  defp read_metadata(metadata_path) do
    case File.read(metadata_path) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, "missing_patch_metadata"}
    end
  end

  defp decode_metadata(json) do
    case Jason.decode(json) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      _other -> {:error, "invalid_patch_metadata"}
    end
  end

  defp resolve_base_ref(context, patch_path, metadata) do
    case context.base_ref_override || Map.get(metadata, "base_ref") do
      base_ref when is_binary(base_ref) and base_ref != "" ->
        {:ok, %{path: patch_path, base_ref: base_ref, base_branch: Map.get(metadata, "base_branch")}}

      _missing ->
        {:error, "missing_base_ref"}
    end
  end

  defp patch_fields(patch) do
    %{base_ref: patch.base_ref, base_branch: patch.base_branch, patch_path: @patch_relative_path}
  end

  defp evaluate_patch(context, patch) do
    case create_eval_workspace(context, patch.base_ref) do
      :ok ->
        result = apply_and_run_gates(context, patch)
        cleanup = cleanup_eval_workspace(context)
        Map.put(result, :cleanup, cleanup)

      {:error, reason} ->
        %{status: :error, reason: reason}
    end
  end

  defp create_eval_workspace(context, base_ref) do
    _removed = File.rm_rf(context.eval_workspace)
    # Drop stale registrations from prior interrupted runs so `worktree add`
    # does not fail with "already registered" for the same run_id path.
    _pruned = git(context, context.workspace, ["worktree", "prune"])

    case git(context, context.workspace, ["worktree", "add", "--detach", context.eval_workspace, base_ref]) do
      {:ok, _output} -> :ok
      {:error, status, output} -> {:error, "worktree_create_failed exit_status=#{status} output=#{cap(output)}"}
    end
  end

  defp apply_and_run_gates(context, patch) do
    case git(context, context.eval_workspace, ["apply", patch.path]) do
      {:ok, output} ->
        context
        |> run_gates()
        |> Map.merge(%{patch_status: "applied", apply_exit_status: 0, apply_output: cap(output)})

      {:error, status, output} ->
        %{
          status: :fail,
          patch_status: "apply_failed",
          apply_exit_status: status,
          apply_output: cap(output)
        }
    end
  end

  defp run_gates(context) do
    case select_gate_selection(context) do
      {:ok, %{gates: []}} ->
        %{status: :pass, gates: nil}

      {:ok, gate_selection} ->
        {action_policy_provider, gate_selection} = action_policy_provider_for_gates(gate_selection, context)

        gate_selection.gates
        |> context.gate_runner.(context.eval_workspace,
          run_dir: context.run_dir,
          gates_dir: @gates_relative_dir,
          gate_selection: Map.drop(gate_selection, [:gates, :action_policy_provider]),
          action_policy: true,
          action_policy_evaluator: action_policy_evaluator(action_policy_provider, context)
        )
        |> gates_outcome()

      {:error, reason} ->
        %{status: :error, reason: "gate_selection_failed #{cap(inspect(reason))}"}
    end
  end

  defp gates_outcome({:ok, summary}), do: %{status: :pass, gates: Gates.summary_to_json(summary)}

  defp gates_outcome({:error, %{status: gate_status, results: _results} = summary}) do
    %{status: gates_status(gate_status), gates: Gates.summary_to_json(summary)}
  end

  defp gates_outcome({:error, reason}), do: %{status: :error, reason: "gate_runner_failed #{cap(inspect(reason))}"}

  defp gates_status(:fail), do: :fail
  defp gates_status(_environment_failure), do: :error

  defp select_gate_selection(%{gates_override: gates}) when is_list(gates) do
    {:ok,
     ProcessProvider.gate_selection_result(gates, metadata: %{provider: "explicit", stage: :pre_pr})
     |> Map.put(:action_policy_provider, Native)}
  end

  defp select_gate_selection(context) do
    opts = gate_selection_opts(context)

    case ProcessProvider.select_gate_selection(context.process_provider, opts) do
      {:ok, selection} ->
        {:ok, Map.put(selection, :action_policy_provider, context.process_provider)}

      {:error, reason} ->
        handle_gate_selection_failure(context.process_provider, reason, opts)
    end
  end

  defp gate_selection_opts(context) do
    [
      workspace: context.eval_workspace,
      source_workspace: context.workspace,
      run_dir: context.run_dir,
      stage: :pre_pr
    ]
    |> maybe_put_source_contract(context.source_contract)
  end

  defp maybe_put_source_contract(opts, source_contract) when is_map(source_contract), do: Keyword.put(opts, :source_contract, source_contract)
  defp maybe_put_source_contract(opts, _source_contract), do: opts

  defp handle_gate_selection_failure(provider, reason, opts) do
    if provider == Native or invalid_artifact_reason?(reason) or Config.process_provider_required?() do
      {:error, reason}
    else
      provider_id = provider_id(provider)
      Logger.warning("Process provider clean-eval gate selection failed provider=#{provider_id} reason=#{inspect(reason)}; falling back to native gates")
      selection = ProcessProvider.select_gate_selection!(Native, opts)

      {:ok, annotate_native_fallback(selection, provider_id, reason) |> Map.put(:action_policy_provider, Native)}
    end
  end

  defp invalid_artifact_reason?({:invalid_artifact_field, _field}), do: true
  defp invalid_artifact_reason?(:invalid_artifact), do: true
  defp invalid_artifact_reason?(:invalid_artifact_id), do: true
  defp invalid_artifact_reason?({:unsupported_artifact_schema, _schema}), do: true
  defp invalid_artifact_reason?({:artifact_not_approved, _status}), do: true
  defp invalid_artifact_reason?({:invalid_json, _path, _message}), do: true
  defp invalid_artifact_reason?(_reason), do: false

  defp action_policy_provider_for_gates(%{action_policy_provider: Beislid} = gate_selection, context) do
    provider = if Beislid.action_policy_available?(provider_opts(context)), do: Beislid, else: Native
    {provider, annotate_action_policy_provider(gate_selection, provider)}
  end

  defp action_policy_provider_for_gates(gate_selection, _context) do
    provider = Map.get(gate_selection, :action_policy_provider, Native)
    {provider, annotate_action_policy_provider(gate_selection, provider)}
  end

  defp action_policy_evaluator(Beislid, context) do
    if Beislid.action_policy_available?(provider_opts(context)) do
      fn action, classes, opts -> Beislid.evaluate_action_policy(action, classes, Keyword.merge(provider_opts(context), opts)) end
    else
      ProcessProvider.action_policy_evaluator(Native)
    end
  end

  defp action_policy_evaluator(provider, _context), do: ProcessProvider.action_policy_evaluator(provider)

  defp provider_opts(context) do
    case context.source_contract do
      source_contract when is_map(source_contract) -> [source_contract: source_contract]
      _other -> []
    end
  end

  defp annotate_native_fallback(selection, provider_id, reason) do
    warning = %{message: "provider #{provider_id} gate selection failed: #{inspect(reason)}; fell back to native gates"}

    selection
    |> Map.update!(:warnings, &[warning | &1])
    |> Map.update!(:metadata, &Map.merge(&1, %{fallback_from: provider_id, fallback_reason: inspect(reason)}))
  end

  defp annotate_action_policy_provider(gate_selection, provider) do
    Map.update!(gate_selection, :metadata, &Map.put(&1, :action_policy_provider, provider_id(provider)))
  end

  defp provider_id(provider) do
    if function_exported?(provider, :id, 0), do: provider.id(), else: inspect(provider)
  end

  defp cleanup_eval_workspace(context) do
    case git(context, context.workspace, ["worktree", "remove", "--force", context.eval_workspace]) do
      {:ok, _output} ->
        %{removed: true, method: "worktree_remove"}

      {:error, _status, _output} ->
        _removed = File.rm_rf(context.eval_workspace)
        _pruned = git(context, context.workspace, ["worktree", "prune"])
        %{removed: !File.exists?(context.eval_workspace), method: "rm_rf"}
    end
  end

  defp persist(ledger, result, started_at) do
    finished_at = DateTime.utc_now()
    payload = result_payload(result, started_at, finished_at)
    result_path = Path.join(ledger.run_dir, @result_relative_path)

    with :ok <- write_json(result_path, payload),
         {:ok, ledger} <- RunLedger.link_artifacts(ledger, result_artifacts(result)),
         {:ok, ledger} <- write_completion_checkpoint(ledger, payload) do
      {:ok, ledger, result}
    end
  end

  defp write_completion_checkpoint(ledger, payload) do
    manifest_update = fn manifest ->
      Map.put(manifest, "clean_eval", %{
        "status" => Map.fetch!(payload, "status"),
        "result_path" => @result_relative_path
      })
    end

    RunLedger.write_checkpoint(ledger, :clean_eval_completed, payload,
      source: %{evaluator: "clean_eval"},
      manifest_update: manifest_update
    )
  end

  defp result_artifacts(result) do
    [%{"kind" => "clean_eval_result", "path" => @result_relative_path}]
    |> Kernel.++(gate_results_artifact(result))
  end

  defp gate_results_artifact(%{gates: %{results_path: results_path}}) when is_binary(results_path) do
    [%{"kind" => "clean_eval_gate_results", "path" => results_path}]
  end

  defp gate_results_artifact(_result), do: []

  defp result_payload(result, started_at, finished_at) do
    %{
      "schema" => @schema,
      "status" => Atom.to_string(result.status),
      "reason" => Map.get(result, :reason),
      "base_ref" => Map.get(result, :base_ref),
      "base_branch" => Map.get(result, :base_branch),
      "patch_path" => Map.get(result, :patch_path),
      "patch_status" => Map.get(result, :patch_status),
      "apply_exit_status" => Map.get(result, :apply_exit_status),
      "apply_output" => Map.get(result, :apply_output),
      "gates" => Map.get(result, :gates),
      "cleanup" => Map.get(result, :cleanup),
      "started_at" => datetime_to_iso(started_at),
      "finished_at" => datetime_to_iso(finished_at)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp write_json(path, payload) do
    with :ok <- mkdir_for(path),
         {:ok, json} <- Jason.encode(payload) do
      File.write(path, json)
    end
  end

  defp mkdir_for(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:clean_eval_result_dir_failed, reason}}
    end
  end

  defp gates_override(opts) do
    if Keyword.has_key?(opts, :gates), do: Keyword.fetch!(opts, :gates), else: nil
  end

  defp process_provider(_ledger, opts) do
    case Keyword.get(opts, :process_provider) do
      nil -> ProcessProvider.provider_module()
      provider -> ProcessProvider.provider_module(provider)
    end
  end

  defp git(context, cwd, args) do
    case context.runner.(args, cwd) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, status, output}
    end
  end

  defp workspace_accessible?(context) do
    match?({:ok, _}, git(context, context.workspace, ["rev-parse", "--git-dir"]))
  end

  defp run_git(args, cwd) do
    System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end

  defp cap(value) when is_binary(value) do
    if byte_size(value) <= @max_apply_output_bytes do
      value
    else
      binary_part(value, 0, @max_apply_output_bytes) <> "... (truncated)"
    end
  end

  defp datetime_to_iso(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
