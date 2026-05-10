defmodule Rondo.Agent.Adapter do
  @moduledoc """
  Provider-neutral boundary for one agent invocation.

  Rondo owns the outer issue loop. Adapter modules own one provider invocation and
  translate provider-native stream/result data into Rondo-normalized events,
  run references, and invocation results while retaining native payloads in
  `:raw` for audit/debugging.
  """

  @event_types [
    :invocation_started,
    :session_started,
    :turn_started,
    :assistant_message,
    :tool_started,
    :tool_updated,
    :tool_completed,
    :diff_updated,
    :usage_updated,
    :rate_limits_updated,
    :approval_requested,
    :invocation_completed,
    :invocation_failed,
    :warning
  ]

  @type event_type ::
          :invocation_started
          | :session_started
          | :turn_started
          | :assistant_message
          | :tool_started
          | :tool_updated
          | :tool_completed
          | :diff_updated
          | :usage_updated
          | :rate_limits_updated
          | :approval_requested
          | :invocation_completed
          | :invocation_failed
          | :warning

  @type run_ref :: %{
          adapter: String.t(),
          provider_ref: String.t() | nil,
          provider_ref_kind: String.t() | nil,
          resumable?: boolean()
        }

  @type normalized_event :: %{
          required(:event_type) => atom(),
          required(:adapter) => String.t() | nil,
          required(:run_ref) => run_ref() | nil,
          required(:usage) => map() | nil,
          required(:rate_limits) => map() | nil,
          required(:diff) => map() | nil,
          required(:raw) => term(),
          optional(:capabilities) => capabilities(),
          optional(:final_report) => String.t() | nil,
          optional(:diff_source) => atom() | String.t() | nil,
          optional(:message) => String.t() | nil,
          optional(:timestamp) => DateTime.t()
        }

  @type capabilities :: map()
  @type probe_status :: :ok | :degraded | :missing | :unsupported
  @type probe_result :: %{status: probe_status(), checks: map()}

  @type invocation_request :: %{
          required(:prompt) => String.t(),
          required(:workspace) => Path.t(),
          required(:previous_run_ref) => run_ref() | nil,
          required(:on_event) => (normalized_event() -> term()),
          optional(:opts) => keyword()
        }

  @type invocation_result :: %{
          required(:run_ref) => run_ref() | nil,
          required(:final_report) => String.t() | nil,
          required(:usage) => map() | nil,
          required(:rate_limits) => map() | nil,
          required(:diff) => map() | nil,
          required(:diff_source) => atom() | String.t() | nil,
          required(:capabilities) => capabilities(),
          required(:probe) => probe_result() | nil,
          required(:raw) => term()
        }

  @callback id() :: String.t()
  @callback capabilities() :: capabilities()
  @callback probe(keyword()) :: probe_result()
  @callback invoke(invocation_request()) :: {:ok, invocation_result()} | {:error, term()}

  @spec event_types() :: [event_type()]
  def event_types, do: @event_types

  @spec run_ref(String.t(), String.t() | nil, String.t() | atom() | nil, boolean()) :: run_ref()
  def run_ref(adapter, provider_ref, provider_ref_kind, resumable?) when is_binary(adapter) and is_boolean(resumable?) do
    %{
      adapter: adapter,
      provider_ref: provider_ref,
      provider_ref_kind: kind_to_string(provider_ref_kind),
      resumable?: resumable?
    }
  end

  @spec event(atom(), keyword()) :: normalized_event()
  def event(event_type, opts \\ []) when is_atom(event_type) and is_list(opts) do
    %{
      event_type: event_type,
      adapter: Keyword.get(opts, :adapter),
      run_ref: Keyword.get(opts, :run_ref),
      usage: Keyword.get(opts, :usage),
      rate_limits: Keyword.get(opts, :rate_limits),
      diff: Keyword.get(opts, :diff),
      raw: Keyword.get(opts, :raw, %{}),
      capabilities: Keyword.get(opts, :capabilities),
      final_report: Keyword.get(opts, :final_report),
      diff_source: Keyword.get(opts, :diff_source),
      message: Keyword.get(opts, :message),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
    }
  end

  @spec result(keyword()) :: invocation_result()
  def result(opts \\ []) when is_list(opts) do
    %{
      run_ref: Keyword.get(opts, :run_ref),
      final_report: Keyword.get(opts, :final_report),
      usage: Keyword.get(opts, :usage),
      rate_limits: Keyword.get(opts, :rate_limits),
      diff: Keyword.get(opts, :diff),
      diff_source: Keyword.get(opts, :diff_source),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      probe: Keyword.get(opts, :probe),
      raw: Keyword.get(opts, :raw, %{})
    }
  end

  @spec probe_result(probe_status(), map()) :: probe_result()
  def probe_result(status, checks \\ %{}) when status in [:ok, :degraded, :missing, :unsupported] and is_map(checks) do
    %{status: status, checks: checks}
  end

  @spec provider_session_id(normalized_event() | run_ref() | nil) :: String.t() | nil
  def provider_session_id(%{run_ref: run_ref}), do: provider_session_id(run_ref)
  def provider_session_id(%{provider_ref_kind: "session_id", provider_ref: provider_ref}) when is_binary(provider_ref), do: provider_ref
  def provider_session_id(%{provider_ref_kind: :session_id, provider_ref: provider_ref}) when is_binary(provider_ref), do: provider_ref
  def provider_session_id(_event_or_run_ref), do: nil

  defp kind_to_string(nil), do: nil
  defp kind_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp kind_to_string(value) when is_binary(value), do: value
  defp kind_to_string(value), do: to_string(value)
end
