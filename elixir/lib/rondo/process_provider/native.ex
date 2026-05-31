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
  def select_gates(_opts \\ []), do: {:ok, Config.gates()}

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

  defp command_status(command) when is_binary(command) do
    case System.find_executable(command) do
      executable when is_binary(executable) -> :ok
      nil -> :missing
    end
  end
end
