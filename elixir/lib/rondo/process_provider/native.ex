defmodule Rondo.ProcessProvider.Native do
  @moduledoc """
  Native ProcessProvider implementation backed by Rondo's `WORKFLOW.md` contract.

  This provider preserves the current standalone Rondo behavior. Rich provider
  features that are not represented in `WORKFLOW.md` degrade to empty or
  unsupported metadata instead of requiring an external provider.
  """

  @behaviour Rondo.ProcessProvider

  alias Rondo.{ActionPolicy, Config, Linear.Issue, ProcessProvider, PromptBuilder}

  @impl true
  def id, do: "native"

  @impl true
  def capabilities do
    %{
      gate_selection: "native_flat_gates",
      guide_selection: "unsupported",
      action_policy: "beislid_evaluator",
      model_routing_hints: "native_adapter_config",
      proof_requirements: "unsupported",
      probes: "native"
    }
  end

  @impl true
  def probe(_opts \\ []) do
    action_policy_status = command_status(Config.action_policy_command())

    status =
      case action_policy_status do
        :ok -> :ok
        _ -> :degraded
      end

    ProcessProvider.probe_result(status, %{
      workflow: :ok,
      gates: :ok,
      prompt: :ok,
      action_policy: action_policy_status,
      guide_selection: :unsupported,
      proof_requirements: :unsupported
    })
  end

  @impl true
  def select_gates(opts \\ []) do
    gates = gates_for_stage(Keyword.get(opts, :stage))

    {:ok,
     ProcessProvider.gate_selection_result(gates,
       selected: Enum.map(gates, &selected_gate_reason(&1, Keyword.get(opts, :stage))),
       changed_files: Keyword.get(opts, :changed_files, []),
       diff_source: changed_files_source(opts),
       metadata: %{provider: id(), source: "WORKFLOW.md", stage: Keyword.get(opts, :stage)}
     )}
  end

  @impl true
  def select_guides(_opts \\ []), do: ProcessProvider.unsupported(:no_native_guide_registry)

  @impl true
  def prompt(%Issue{} = issue, opts \\ []), do: PromptBuilder.build_prompt(issue, opts)

  @impl true
  def model_routing_hints(_opts \\ []) do
    %{
      claude_model: Config.claude_model(),
      claude_allowed_tools: Config.claude_allowed_tools(),
      agent_adapter: Config.agent_adapter()
    }
  end

  @impl true
  def proof_requirements(_opts \\ []), do: ProcessProvider.unsupported(:no_native_proof_requirements)

  @impl true
  def evaluate_action_policy(action, classes, opts \\ []) do
    ActionPolicy.evaluate(action, classes, opts)
  end

  defp gates_for_stage(:pre_pr), do: Config.clean_eval_gates()
  defp gates_for_stage("pre_pr"), do: Config.clean_eval_gates()
  defp gates_for_stage(_stage), do: Config.gates()

  defp changed_files_source(opts) do
    opts
    |> Keyword.get(:changed_files_metadata, %{})
    |> Map.get(:source)
  end

  defp selected_gate_reason(gate, :pre_pr) do
    %{name: Map.get(gate, :name, "gate"), reason: "selected from clean_eval/top-level gates for native pre-PR clean evaluation"}
  end

  defp selected_gate_reason(gate, "pre_pr"), do: selected_gate_reason(gate, :pre_pr)

  defp selected_gate_reason(gate, _stage) do
    %{name: Map.get(gate, :name, "gate"), reason: "selected from flat WORKFLOW.md gates by native process provider"}
  end

  defp command_status(command) when is_binary(command) do
    case System.find_executable(command) do
      executable when is_binary(executable) -> :ok
      nil -> :missing
    end
  end
end
