defmodule Rondo.ProcessProvider do
  @moduledoc """
  Provider-neutral boundary for process/workflow decisions.

  Rondo owns execution, proof artifacts, and run state. Process providers own
  optional work-contract inputs such as gate selection, guide selection, action
  policy, model hints, proof requirements, and capability/probe reporting.
  """

  alias Rondo.{Config, Linear.Issue}
  alias Rondo.ProcessProvider.Native

  @type capability_status :: :ok | :degraded | :unsupported | :missing
  @type capabilities :: map()
  @type probe_result :: %{status: capability_status(), checks: map()}
  @type gate_selection :: {:ok, [Config.gate()]} | {:error, term()}
  @type guide_selection :: {:ok, [map()]} | {:error, term()}
  @type proof_requirements :: {:ok, [map()]} | {:error, term()}

  @callback id() :: String.t()
  @callback capabilities() :: capabilities()
  @callback probe(keyword()) :: probe_result()
  @callback select_gates(keyword()) :: gate_selection()
  @callback select_guides(keyword()) :: guide_selection()
  @callback prompt(Issue.t(), keyword()) :: String.t()
  @callback model_routing_hints(keyword()) :: map()
  @callback proof_requirements(keyword()) :: proof_requirements()
  @callback evaluate_action_policy(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}

  @spec provider_module() :: module()
  def provider_module do
    Config.process_provider_kind()
    |> provider_module()
  end

  @spec provider_module(String.t() | atom() | module()) :: module()
  def provider_module("native"), do: Native
  def provider_module(:native), do: Native
  def provider_module(module) when is_atom(module), do: module

  @spec select_gates!(module(), keyword()) :: [Config.gate()]
  def select_gates!(provider \\ provider_module(), opts \\ []) do
    case provider.select_gates(opts) do
      {:ok, gates} -> gates
      {:error, reason} -> raise RuntimeError, "process_provider_gate_selection_failed: #{inspect(reason)}"
    end
  end

  @spec prompt(module(), Issue.t(), keyword()) :: String.t()
  def prompt(provider \\ provider_module(), %Issue{} = issue, opts \\ []) do
    provider.prompt(issue, opts)
  end

  @spec action_policy_evaluator(module()) :: (String.t(), [String.t()], keyword() -> {:ok, map()} | {:error, term()})
  def action_policy_evaluator(provider \\ provider_module()) do
    fn action, classes, opts -> provider.evaluate_action_policy(action, classes, opts) end
  end

  @spec unsupported(term()) :: {:ok, []}
  def unsupported(_reason \\ nil), do: {:ok, []}

  @spec probe_result(capability_status(), map()) :: probe_result()
  def probe_result(status, checks \\ %{}) when status in [:ok, :degraded, :unsupported, :missing] and is_map(checks) do
    %{status: status, checks: checks}
  end
end
