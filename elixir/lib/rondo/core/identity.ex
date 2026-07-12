defmodule Rondo.Core.Identity do
  @moduledoc """
  Process-scoped identity and readiness for the loopback Core service.
  """

  alias Rondo.{Config, Orchestrator}

  @surface "rondo.core/v1"
  @instance_key {__MODULE__, :instance_id}

  @spec initialize() :: :ok
  def initialize do
    :global.trans({{__MODULE__, :initialize}, self()}, fn ->
      case :persistent_term.get(@instance_key, nil) do
        nil -> :persistent_term.put(@instance_key, generate_instance_id())
        _instance_id -> :ok
      end
    end)
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(orchestrator \\ Orchestrator) do
    :ok = initialize()

    case Orchestrator.active_run_count(orchestrator) do
      count when is_integer(count) and count >= 0 -> health(true, count)
      :unavailable -> health(false, 0)
    end
  end

  defp health(ready, active_run_count) do
    %{
      "surface" => @surface,
      "runtime_version" => runtime_version(),
      "instance_id" => :persistent_term.get(@instance_key),
      "service_mode" => service_mode(),
      "ready" => ready,
      "active_run_count" => active_run_count
    }
  end

  defp runtime_version do
    case Application.spec(:rondo, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp service_mode do
    case Config.service_mode() do
      :trackerless_core -> "trackerless_core"
      :tracker_daemon -> "tracker_daemon"
      :invalid -> raise "invalid Rondo service mode"
    end
  end

  defp generate_instance_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    Enum.join(
      [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)],
      "-"
    )
  end

  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
