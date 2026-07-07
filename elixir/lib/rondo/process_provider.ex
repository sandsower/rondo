defmodule Rondo.ProcessProvider do
  @moduledoc """
  Provider-neutral boundary for process/workflow decisions.

  Rondo owns execution, proof artifacts, and run state. Process providers own
  optional work-contract inputs such as gate selection, guide selection, action
  policy, model hints, proof requirements, and capability/probe reporting.
  """

  alias Rondo.{Config, Linear.Issue}
  alias Rondo.ProcessProvider.{Beislid, Failure, Native}

  @type capability_status :: :ok | :degraded | :unsupported | :missing
  @type capabilities :: map()
  @type probe_result :: %{status: capability_status(), checks: map()}
  @type gate_selection_reason :: %{
          name: String.t(),
          reason: String.t()
        }
  @type gate_selection_result :: %{
          required(:gates) => [Config.gate()],
          required(:selected) => [gate_selection_reason()],
          required(:skipped) => [gate_selection_reason()],
          required(:warnings) => [map()],
          required(:metadata) => map(),
          optional(:changed_files) => [String.t()],
          optional(:diff_source) => String.t() | atom() | nil
        }
  @type gate_selection :: {:ok, [Config.gate()] | gate_selection_result()} | {:error, term()}
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
  def provider_module("beislid"), do: Beislid
  def provider_module(:beislid), do: Beislid
  def provider_module(module) when is_atom(module), do: module

  @spec select_gate_selection(module(), keyword()) :: {:ok, gate_selection_result()} | {:error, term()}
  def select_gate_selection(provider \\ provider_module(), opts \\ []) do
    case provider.select_gates(opts) do
      {:ok, selection} -> {:ok, normalize_gate_selection(selection)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec select_gate_selection!(module(), keyword()) :: gate_selection_result()
  def select_gate_selection!(provider \\ provider_module(), opts \\ []) do
    case select_gate_selection(provider, opts) do
      {:ok, selection} -> selection
      {:error, reason} -> raise RuntimeError, "process_provider_gate_selection_failed: #{inspect(reason)}"
    end
  end

  @spec select_gates!(module(), keyword()) :: [Config.gate()]
  def select_gates!(provider \\ provider_module(), opts \\ []) do
    provider
    |> select_gate_selection!(opts)
    |> Map.fetch!(:gates)
  end

  @spec prompt(module(), Issue.t(), keyword()) :: String.t()
  def prompt(provider \\ provider_module(), %Issue{} = issue, opts \\ []) do
    provider.prompt(issue, opts)
  end

  @spec proof_requirements(module(), keyword()) :: proof_requirements()
  def proof_requirements(provider \\ provider_module(), opts \\ []) do
    provider.proof_requirements(opts)
  end

  @spec action_policy_evaluator(module()) :: (String.t(), [String.t()], keyword() -> {:ok, map()} | {:error, term()})
  def action_policy_evaluator(provider \\ provider_module()) do
    fn action, classes, opts -> provider.evaluate_action_policy(action, classes, opts) end
  end

  @spec failure_payload(module() | atom() | String.t(), atom() | String.t(), term(), keyword()) :: map()
  def failure_payload(provider, phase, reason, opts \\ []) do
    Failure.payload(provider, phase, reason, opts)
  end

  @spec gate_selection_result([Config.gate()], keyword()) :: gate_selection_result()
  def gate_selection_result(gates, opts \\ []) when is_list(gates) do
    %{
      gates: gates,
      selected: Keyword.get(opts, :selected, default_selected_reasons(gates)),
      skipped: Keyword.get(opts, :skipped, []),
      warnings: Keyword.get(opts, :warnings, []),
      metadata: Keyword.get(opts, :metadata, %{}),
      changed_files: Keyword.get(opts, :changed_files, []),
      diff_source: Keyword.get(opts, :diff_source)
    }
    |> drop_nil_values()
  end

  @spec unsupported(term()) :: {:ok, []}
  def unsupported(_reason \\ nil), do: {:ok, []}

  @spec probe_result(capability_status(), map()) :: probe_result()
  def probe_result(status, checks \\ %{}) when status in [:ok, :degraded, :unsupported, :missing] and is_map(checks) do
    %{status: status, checks: checks}
  end

  defp normalize_gate_selection(%{gates: gates} = selection) when is_list(gates) do
    %{
      gates: gates,
      selected: Map.get(selection, :selected, default_selected_reasons(gates)),
      skipped: Map.get(selection, :skipped, []),
      warnings: Map.get(selection, :warnings, []),
      metadata: Map.get(selection, :metadata, %{}),
      changed_files: Map.get(selection, :changed_files, []),
      diff_source: Map.get(selection, :diff_source)
    }
    |> drop_nil_values()
  end

  defp normalize_gate_selection(gates) when is_list(gates), do: gate_selection_result(gates)

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp default_selected_reasons(gates) do
    Enum.map(gates, fn gate ->
      %{name: Map.get(gate, :name, "gate"), reason: "selected by process provider"}
    end)
  end
end
