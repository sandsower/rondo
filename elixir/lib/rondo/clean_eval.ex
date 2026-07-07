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

  ## Executable command proofs (`command_proofs`)

  Distinct from the `proof_requirements` / proof-requirement-v1 attestation
  contract (declared proof obligations, never executed here), `command_proofs`
  is a new, optional manifest key carrying deterministic, executable
  verification commands: `[{id, command, description?, timeout_seconds?,
  expected_exit?}]`. When present (via the `:command_proofs` option or the
  `command_proofs` key on the run ledger manifest), each proof runs — after the
  repo gates pass, in the same clean worktree, through the same `:gate_runner`
  seam and frozen per-run action policy used for gates — and is graded purely
  by exit-code equality against `expected_exit` (default `0`). A proof's real
  exit code always survives into the result (`exit_code`), independent of its
  `expected_exit`; only the pass/fail verdict is derived from equality with
  `expected_exit`.

  Outcomes join the result as `command_proofs_declared` (boolean) and, when
  proofs were declared, a `proofs` list of `{id, status, exit_code, log_path,
  stderr_path, duration_ms}` (`status` one of `pass | fail | error | timeout`),
  with per-proof stdout/stderr logs under `clean_eval/proofs/`. A `fail`
  (wrong exit code) rolls the overall clean-eval status up to `:fail`
  (code_failure, same-tier repair loop); `error`/`timeout` (including a
  policy-blocked/denied proof, or the executable not being found) rolls up to
  `:error` (environment_failure, retryable) — mirroring the gate taxonomy.
  Absent or empty `command_proofs` is not an error for native or legacy runs: it
  is recorded as `command_proofs_declared: false` (or `true` with an empty
  `proofs` list) and logged as a warning, for back-compat with existing
  envelopes. If a process-provider artifact declares proof requirements and no
  executable pre-PR gate or command proof covers them, clean evaluation fails
  closed instead of silently accepting unexecuted proof obligations. A malformed
  `command_proofs` manifest value (not a list, missing required
  `id`/`command`, duplicate ids, or an invalid `timeout_seconds`/`expected_exit`)
  is an evaluator `:error`, never silently ignored. Proofs never run when the
  repo gates fail or error, or when the patch fails to apply.
  """

  require Logger

  alias Rondo.{Config, Gates, ProcessProvider, RunLedger}
  alias Rondo.ProcessProvider.{Beislid, Native}

  @schema "rondo.clean_eval/v0"
  @patch_relative_path "artifacts/changes.patch"
  @patch_metadata_relative_path "artifacts/patch.json"
  @result_relative_path "clean_eval/result.json"
  @gates_relative_dir "clean_eval/gates"
  @proofs_relative_dir "clean_eval/proofs"
  @eval_root_dirname ".rondo_clean_eval"
  @max_apply_output_bytes 16_384
  @default_proof_timeout_ms 120_000
  @default_expected_exit 0
  @proof_command_not_found_exit_status 127

  @type status :: :pass | :fail | :error | :skipped
  @type proof_status :: :pass | :fail | :error | :timeout
  @type command_proof :: %{
          id: String.t(),
          command: String.t(),
          description: String.t() | nil,
          timeout_ms: pos_integer(),
          expected_exit: integer()
        }
  @type proof_result :: %{
          required(:id) => String.t(),
          required(:status) => proof_status(),
          required(:exit_code) => integer() | nil,
          optional(:log_path) => String.t(),
          optional(:stderr_path) => String.t(),
          optional(:description) => String.t(),
          optional(:duration_ms) => non_neg_integer()
        }
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

    case persist(ledger, result, started_at) do
      {:ok, persisted_ledger, persisted_result} = ok ->
        Rondo.Telemetry.clean_eval_stop(persisted_ledger.run_id, persisted_result.status)
        ok

      {:error, _reason} = error ->
        error
    end
  end

  defp build_context(ledger, opts) do
    workspace_root = get_in(ledger.manifest, ["repo", "workspace_root"])

    %{
      run_id: ledger.run_id,
      run_dir: ledger.run_dir,
      workspace: Keyword.get(opts, :workspace, get_in(ledger.manifest, ["repo", "workspace"])),
      eval_workspace: eval_workspace_path(workspace_root, ledger.run_id),
      base_ref_override: Keyword.get(opts, :base_ref, Config.clean_eval_base_ref()),
      gates_override: gates_override(opts),
      process_provider: process_provider(ledger, opts),
      source_contract: Keyword.get(opts, :source_contract, Map.get(ledger.manifest, "source_contract")),
      gate_runner: Keyword.get(opts, :gate_runner, &Gates.run/3),
      runner: Keyword.get(opts, :runner, &run_git/2),
      command_proofs_raw: Keyword.get(opts, :command_proofs, Map.get(ledger.manifest, "command_proofs"))
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
        {gates_result, action_policy_provider} = run_gates(context)

        gates_result
        |> Map.merge(maybe_run_command_proofs(context, gates_result, action_policy_provider))
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
      {:ok, %{gates: []} = gate_selection} ->
        {empty_gate_selection_outcome(gate_selection), Native}

      {:ok, gate_selection} ->
        case action_policy_provider_for_gates(gate_selection, context) do
          {:ok, action_policy_provider, gate_selection} ->
            result =
              gate_selection.gates
              |> context.gate_runner.(context.eval_workspace,
                run_dir: context.run_dir,
                gates_dir: @gates_relative_dir,
                gate_selection: Map.drop(gate_selection, [:gates, :action_policy_provider]),
                action_policy: true,
                action_policy_evaluator: action_policy_evaluator(action_policy_provider, context)
              )
              |> process_provider_gate_outcome(action_policy_provider, context)

            {result, action_policy_provider}

          {:error, reason} ->
            {process_provider_failure_outcome(reason), Native}
        end

      {:error, reason} ->
        {process_provider_failure_outcome(reason), Native}
    end
  end

  # Executable command-proof verification (`command_proofs`). Runs only after the
  # repo gates pass, reusing the same `:gate_runner` seam and action-policy
  # provider/evaluator resolved for the gates, so proofs execute under the same
  # frozen per-run action policy as any other run-owned side effect.
  defp maybe_run_command_proofs(context, %{status: :pass} = gates_result, action_policy_provider) do
    case fetch_command_proofs(context) do
      {:ok, nil} ->
        missing_command_proofs_outcome(context, gates_result)

      {:ok, []} ->
        empty_command_proofs_outcome(context, gates_result)

      {:ok, proofs} ->
        run_command_proofs(context, proofs, action_policy_provider)

      {:error, reason} ->
        %{status: :error, reason: "invalid_command_proofs #{reason}"}
    end
  end

  defp maybe_run_command_proofs(_context, _gates_result, _action_policy_provider), do: %{}

  defp missing_command_proofs_outcome(context, gates_result) do
    case declared_proof_requirements(context) do
      {:ok, []} ->
        Logger.warning("clean_eval: run #{context.run_id} declares no command_proofs; skipping deterministic proof verification (back-compat, not a failure)")

        %{command_proofs_declared: false, proof_requirements_declared: false}

      {:ok, proof_requirements} ->
        proof_requirements_without_command_proofs_outcome(context, gates_result, proof_requirements, false)

      {:error, reason} ->
        %{status: :error, reason: "proof_requirements_unavailable #{inspect(reason)}", command_proofs_declared: false}
    end
  end

  defp empty_command_proofs_outcome(context, gates_result) do
    case declared_proof_requirements(context) do
      {:ok, []} ->
        %{command_proofs_declared: true, proof_requirements_declared: false, proofs: []}

      {:ok, proof_requirements} ->
        proof_requirements_without_command_proofs_outcome(context, gates_result, proof_requirements, true)

      {:error, reason} ->
        %{status: :error, reason: "proof_requirements_unavailable #{inspect(reason)}", command_proofs_declared: true, proofs: []}
    end
  end

  defp proof_requirements_without_command_proofs_outcome(context, gates_result, proof_requirements, command_proofs_declared?) do
    if gates_result_has_executable_results?(gates_result) do
      %{
        command_proofs_declared: command_proofs_declared?,
        proof_requirements_declared: true,
        proof_requirements: proof_requirements,
        proofs: if(command_proofs_declared?, do: [], else: nil)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    else
      reason =
        if command_proofs_declared? do
          "empty_command_proofs_for_declared_proof_requirements"
        else
          "missing_command_proofs_for_declared_proof_requirements"
        end

      %{
        status: :error,
        reason: reason,
        command_proofs_declared: command_proofs_declared?,
        proof_requirements_declared: true,
        proof_requirements: proof_requirements,
        proofs: if(command_proofs_declared?, do: [], else: nil),
        run_id: context.run_id
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  defp gates_result_has_executable_results?(%{gates: %{"results" => results}}) when is_list(results), do: results != []
  defp gates_result_has_executable_results?(%{gates: %{results: results}}) when is_list(results), do: results != []
  defp gates_result_has_executable_results?(_gates_result), do: false

  defp declared_proof_requirements(context) do
    case ProcessProvider.proof_requirements(context.process_provider, provider_opts(context)) do
      {:ok, requirements} when is_list(requirements) -> {:ok, requirements}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_command_proofs(context, proofs, action_policy_provider) do
    proof_gates = Enum.map(proofs, &proof_gate_definition/1)

    proof_gates
    |> context.gate_runner.(context.eval_workspace,
      run_dir: context.run_dir,
      gates_dir: @proofs_relative_dir,
      action_policy: true,
      action_policy_evaluator: action_policy_evaluator(action_policy_provider, context)
    )
    |> command_proofs_outcome(proofs)
  end

  defp proof_gate_definition(proof) do
    %{
      name: proof.id,
      command: proof.command,
      timeout_ms: proof.timeout_ms,
      action_id: "command_proof.#{proof.id}",
      action_classes: ["workspace-write"]
    }
  end

  defp command_proofs_outcome({:ok, summary}, proofs), do: build_command_proofs_result(summary, proofs)

  defp command_proofs_outcome({:error, %{results: _results} = summary}, proofs), do: build_command_proofs_result(summary, proofs)

  defp command_proofs_outcome({:error, reason}, _proofs) do
    %{status: :error, reason: "command_proofs_runner_failed #{cap(inspect(reason))}"}
  end

  defp build_command_proofs_result(summary, proofs) do
    proof_by_id = Map.new(proofs, &{&1.id, &1})

    results =
      Enum.map(summary.results, fn gate_result ->
        classify_proof_result(Map.fetch!(proof_by_id, gate_result.name), gate_result)
      end)

    %{status: overall_command_proofs_status(results), command_proofs_declared: true, proofs: results}
  end

  defp classify_proof_result(proof, gate_result) do
    %{
      id: proof.id,
      status: proof_result_status(gate_result, proof.expected_exit),
      exit_code: Map.get(gate_result, :exit_status),
      log_path: Map.get(gate_result, :stdout_path),
      stderr_path: Map.get(gate_result, :stderr_path),
      duration_ms: Map.get(gate_result, :duration_ms)
    }
    |> maybe_put_description(proof.description)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp proof_result_status(%{status: status}, _expected_exit) when status in [:policy_blocked, :policy_denied], do: :error
  defp proof_result_status(%{status: :timeout}, _expected_exit), do: :timeout
  defp proof_result_status(%{exit_status: @proof_command_not_found_exit_status}, _expected_exit), do: :error
  defp proof_result_status(%{exit_status: exit_status}, expected_exit) when exit_status == expected_exit, do: :pass
  defp proof_result_status(_gate_result, _expected_exit), do: :fail

  defp overall_command_proofs_status(results) do
    cond do
      Enum.any?(results, &(&1.status == :fail)) -> :fail
      Enum.any?(results, &(&1.status in [:error, :timeout])) -> :error
      true -> :pass
    end
  end

  defp maybe_put_description(map, nil), do: map
  defp maybe_put_description(map, description), do: Map.put(map, :description, description)

  defp fetch_command_proofs(context) do
    case context.command_proofs_raw do
      nil -> {:ok, nil}
      list when is_list(list) -> normalize_command_proofs(list)
      _other -> {:error, "command_proofs must be a list"}
    end
  end

  defp normalize_command_proofs(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, &accumulate_command_proof/2)
    |> case do
      {:ok, proofs, _seen_ids} -> {:ok, Enum.reverse(proofs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp accumulate_command_proof({item, index}, {:ok, acc, seen_ids}) do
    with {:ok, proof} <- normalize_command_proof(item, index),
         :ok <- ensure_unique_proof_id(proof.id, seen_ids) do
      {:cont, {:ok, [proof | acc], MapSet.put(seen_ids, proof.id)}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp ensure_unique_proof_id(id, seen_ids) do
    if MapSet.member?(seen_ids, id) do
      {:error, "duplicate command_proofs id #{inspect(id)}"}
    else
      :ok
    end
  end

  defp normalize_command_proof(%{"id" => id, "command" => command} = item, _index) when is_binary(id) and is_binary(command) do
    id = String.trim(id)
    command = String.trim(command)

    cond do
      id == "" -> {:error, "command_proofs item has a blank id"}
      command == "" -> {:error, "command_proofs item #{inspect(id)} has a blank command"}
      true -> normalize_command_proof_fields(id, command, item)
    end
  end

  defp normalize_command_proof(item, index) when is_map(item) do
    {:error, "command_proofs item at index #{index} is missing required id/command fields"}
  end

  defp normalize_command_proof(_item, index) do
    {:error, "command_proofs item at index #{index} must be an object"}
  end

  defp normalize_command_proof_fields(id, command, item) do
    with {:ok, timeout_ms} <- normalize_proof_timeout(Map.get(item, "timeout_seconds"), id),
         {:ok, expected_exit} <- normalize_proof_expected_exit(Map.get(item, "expected_exit"), id) do
      {:ok,
       %{
         id: id,
         command: command,
         description: proof_string_or_nil(Map.get(item, "description")),
         timeout_ms: timeout_ms,
         expected_exit: expected_exit
       }}
    end
  end

  defp normalize_proof_timeout(nil, _id), do: {:ok, @default_proof_timeout_ms}
  defp normalize_proof_timeout(seconds, _id) when is_number(seconds) and seconds > 0, do: {:ok, round(seconds * 1000)}
  defp normalize_proof_timeout(_seconds, id), do: {:error, "command_proofs item #{inspect(id)} has an invalid timeout_seconds"}

  defp normalize_proof_expected_exit(nil, _id), do: {:ok, @default_expected_exit}
  defp normalize_proof_expected_exit(exit_code, _id) when is_integer(exit_code), do: {:ok, exit_code}
  defp normalize_proof_expected_exit(_exit_code, id), do: {:error, "command_proofs item #{inspect(id)} has an invalid expected_exit"}

  defp proof_string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp proof_string_or_nil(_value), do: nil

  defp empty_gate_selection_outcome(gate_selection) do
    metadata = Map.get(gate_selection, :metadata, %{})
    changed_files = Map.get(gate_selection, :changed_files, [])

    if Map.get(metadata, :selector_mode) == "changed_files" and changed_files != [] do
      %{status: :error, reason: "gate_selection_empty #{cap(inspect(empty_gate_selection_reason(gate_selection)))}"}
    else
      %{status: :pass, gates: nil}
    end
  end

  defp empty_gate_selection_reason(gate_selection) do
    %{
      changed_files: Map.get(gate_selection, :changed_files, []),
      skipped: Map.get(gate_selection, :skipped, []),
      warnings: Map.get(gate_selection, :warnings, [])
    }
  end

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

  defp process_provider_failure_outcome({kind, payload}) when kind in [:process_provider_failed, :process_provider_required_failed] do
    %{
      status: :error,
      reason: Map.get(payload, :message) || Map.get(payload, "message") || Map.get(payload, :reason) || inspect(payload),
      reason_code: Map.get(payload, :reason_code) || Map.get(payload, "reason_code"),
      process_provider_failure: payload
    }
  end

  defp process_provider_gate_outcome({:ok, summary}, _provider, _context), do: %{status: :pass, gates: Gates.summary_to_json(summary)}

  defp process_provider_gate_outcome({:error, %{status: status} = summary}, Beislid, context)
       when status in [:policy_blocked, "policy_blocked", :policy_denied, "policy_denied"] do
    if Config.process_provider_required?() do
      payload =
        process_provider_failure_payload(
          Beislid,
          :action_policy,
          gate_failure_reason(summary),
          provider_opts(context),
          true
        )

      process_provider_failure_outcome({:process_provider_required_failed, payload})
    else
      %{status: gates_status(status), gates: Gates.summary_to_json(summary)}
    end
  end

  defp process_provider_gate_outcome({:error, %{status: gate_status, results: _results} = summary}, _provider, _context)
       when gate_status in [:fail, :policy_blocked, :policy_denied, "fail", "policy_blocked", "policy_denied"] do
    %{status: gates_status(gate_status), gates: Gates.summary_to_json(summary)}
  end

  defp process_provider_gate_outcome({:error, reason}, _provider, _context) do
    if is_map(reason) and (Map.has_key?(reason, :results) || Map.has_key?(reason, "results")) do
      %{status: gates_status(Map.get(reason, :status) || Map.get(reason, "status")), gates: Gates.summary_to_json(reason)}
    else
      %{status: :error, reason: "gate_runner_failed #{cap(inspect(reason))}"}
    end
  end

  defp handle_gate_selection_failure(provider, reason, opts) do
    required? = Config.process_provider_required?()
    payload = process_provider_failure_payload(provider, :gate_selection, reason, opts, required?)

    cond do
      required? ->
        {:error, {:process_provider_required_failed, payload}}

      provider == Native or invalid_artifact_reason?(reason) ->
        {:error, {:process_provider_failed, payload}}

      true ->
        provider_id = provider_id(provider)
        Logger.warning("Process provider clean-eval gate selection failed provider=#{provider_id} reason=#{inspect(reason)}; falling back to native gates")

        {:ok, selection} = ProcessProvider.select_gate_selection(Native, opts)
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
    required? = Config.process_provider_required?()
    opts = provider_opts(context)

    if Beislid.action_policy_available?(opts) do
      provider = Beislid
      {:ok, provider, annotate_action_policy_provider(gate_selection, provider)}
    else
      payload = process_provider_failure_payload(Beislid, :action_policy, :action_policy_unavailable, opts, required?)

      if required? do
        {:error, {:process_provider_required_failed, payload}}
      else
        provider = Native

        selection =
          gate_selection
          |> annotate_native_fallback(provider_id(Beislid), :action_policy_unavailable)
          |> annotate_action_policy_provider(provider)

        {:ok, provider, selection}
      end
    end
  end

  defp action_policy_provider_for_gates(gate_selection, _context) do
    provider = Map.get(gate_selection, :action_policy_provider, Native)
    {:ok, provider, annotate_action_policy_provider(gate_selection, provider)}
  end

  defp action_policy_evaluator(Beislid, context) do
    fn action, classes, opts -> Beislid.evaluate_action_policy(action, classes, Keyword.merge(provider_opts(context), opts)) end
  end

  defp action_policy_evaluator(provider, _context), do: ProcessProvider.action_policy_evaluator(provider)

  defp process_provider_failure_payload(provider, phase, reason, opts, required?) do
    ProcessProvider.failure_payload(provider, phase, reason, Keyword.put(opts, :required, required?))
  end

  defp gate_failure_reason(%{status: status} = summary) when status in [:policy_blocked, "policy_blocked"] do
    case policy_gate_result(summary, [:policy_blocked, "policy_blocked"]) do
      nil -> {:gate_failed, gate_error_summary(summary)}
      result -> {:action_policy_guidance_required, gate_policy_envelope(result)}
    end
  end

  defp gate_failure_reason(%{status: status} = summary) when status in [:policy_denied, "policy_denied"] do
    case policy_gate_result(summary, [:policy_denied, "policy_denied"]) do
      nil -> {:gate_failed, gate_error_summary(summary)}
      result -> {:action_policy_denied, gate_policy_envelope(result)}
    end
  end

  defp gate_error_summary(summary) do
    %{
      status: summary.status,
      failed: Enum.map(summary.results, &Map.take(&1, [:name, :status, :exit_status, :retryable, :environment_failure]))
    }
  end

  defp policy_gate_result(summary, statuses) when is_list(statuses) do
    Enum.find(List.wrap(summary.results), fn result ->
      status = Map.get(result, :status)
      status_text = if is_atom(status), do: Atom.to_string(status), else: status
      status in statuses or status_text in statuses
    end)
  end

  defp gate_policy_envelope(result), do: Map.get(result, :policy_decision) || %{}

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
    # `function_exported?/3` never loads a module implicitly, so without
    # `Code.ensure_loaded?/1` this falls back to `inspect/1` whenever `provider`
    # hasn't happened to be loaded yet elsewhere in the VM - an order-dependent
    # flake (e.g. reproducible when running a single test in isolation). `id/0`
    # is a required `Rondo.ProcessProvider` callback, so every real provider
    # implements it once loaded.
    if Code.ensure_loaded?(provider) and function_exported?(provider, :id, 0) do
      provider.id()
    else
      inspect(provider)
    end
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
    |> Kernel.++(proof_log_artifacts(result))
  end

  defp gate_results_artifact(%{gates: %{results_path: results_path}}) when is_binary(results_path) do
    [%{"kind" => "clean_eval_gate_results", "path" => results_path}]
  end

  defp gate_results_artifact(_result), do: []

  defp proof_log_artifacts(%{proofs: proofs}) when is_list(proofs) do
    Enum.flat_map(proofs, fn proof ->
      [
        proof_log_artifact("clean_eval_proof_stdout", Map.get(proof, :log_path)),
        proof_log_artifact("clean_eval_proof_stderr", Map.get(proof, :stderr_path))
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp proof_log_artifacts(_result), do: []

  defp proof_log_artifact(_kind, nil), do: nil
  defp proof_log_artifact(kind, path), do: %{"kind" => kind, "path" => path}

  defp result_payload(result, started_at, finished_at) do
    %{
      "schema" => @schema,
      "status" => Atom.to_string(result.status),
      "reason" => Map.get(result, :reason),
      "reason_code" => Map.get(result, :reason_code),
      "process_provider_failure" => Map.get(result, :process_provider_failure),
      "base_ref" => Map.get(result, :base_ref),
      "base_branch" => Map.get(result, :base_branch),
      "patch_path" => Map.get(result, :patch_path),
      "patch_status" => Map.get(result, :patch_status),
      "apply_exit_status" => Map.get(result, :apply_exit_status),
      "apply_output" => Map.get(result, :apply_output),
      "gates" => Map.get(result, :gates),
      "command_proofs_declared" => Map.get(result, :command_proofs_declared),
      "proof_requirements_declared" => Map.get(result, :proof_requirements_declared),
      "proof_requirements" => Map.get(result, :proof_requirements),
      "proofs" => Map.get(result, :proofs),
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

  defp process_provider(ledger, opts) do
    case Keyword.get(opts, :process_provider) do
      nil -> process_provider_from_manifest_or_config(ledger)
      provider -> ProcessProvider.provider_module(provider)
    end
  end

  defp process_provider_from_manifest_or_config(ledger) do
    source_contract = Map.get(ledger.manifest, "source_contract") || %{}

    if source_contract_process_provider_artifact?(source_contract) do
      Beislid
    else
      ProcessProvider.provider_module()
    end
  end

  defp source_contract_process_provider_artifact?(%{"process_provider" => %{"artifact_path" => path}}) when is_binary(path) do
    String.trim(path) != ""
  end

  defp source_contract_process_provider_artifact?(_source_contract), do: false

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
