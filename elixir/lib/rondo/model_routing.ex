defmodule Rondo.ModelRouting do
  @moduledoc """
  Resolves provider-neutral model routing hints into concrete per-run adapter and
  model choices.
  """

  alias Rondo.Config

  @tiers ~w(light standard heavy frontier)
  @tier_rank Enum.with_index(@tiers) |> Map.new()
  @default_candidates %{
    "light" => [%{adapter: "claude_code", model: "haiku"}],
    "standard" => [%{adapter: "claude_code", model: "sonnet"}],
    "heavy" => [%{adapter: "claude_code", model: "opus"}],
    "frontier" => [%{adapter: "claude_code", model: "opus"}]
  }

  @type candidate :: %{adapter: String.t() | nil, model: String.t() | nil}
  @type routing_status :: %{
          status: :honored | :fallback | :unsupported | :blocked,
          mode: :prefer | :require,
          requested_tier: String.t() | nil,
          candidates: [candidate()],
          resolved: candidate() | nil,
          reason: String.t()
        }

  @spec resolve(keyword()) :: routing_status()
  def resolve(opts \\ []) when is_list(opts) do
    repo_routing = Keyword.get_lazy(opts, :repo_model_routing, &Config.model_routing/0)
    hints = effective_hints(opts)
    requested_tier = normalize_tier(map_value(hints, :tier))
    floor_tier = repo_floor_tier(repo_routing)
    effective_tier = effective_tier(requested_tier, floor_tier)
    model = normalize_model(map_value(hints, :model)) || normalize_model(map_value(hints, :claude_model))
    adapter = normalize_adapter(map_value(hints, :agent_adapter)) || normalize_adapter(map_value(hints, :adapter))
    mode = normalize_mode(map_value(hints, :mode), map_value(hints, :required))
    candidates = candidates_for_hint(effective_tier, model, adapter, repo_routing)
    resolved = List.first(candidates)
    floor_fallback? = floor_fallback?(requested_tier, floor_tier)

    %{
      status: status(mode, resolved, floor_fallback?),
      mode: mode,
      requested_tier: requested_tier,
      candidates: candidates,
      resolved: resolved,
      reason: reason(requested_tier, effective_tier, resolved, mode, floor_fallback?)
    }
  end

  defp effective_hints(opts) do
    opts
    |> source_contract_hints()
    |> first_non_empty(Keyword.get(opts, :model_routing_hints, %{}) || %{})
  end

  defp source_contract_hints(opts) do
    opts
    |> Keyword.get(:source_contract, %{})
    |> map_value(:model_routing)
    |> case do
      hints when is_map(hints) -> hints
      _hints -> %{}
    end
  end

  defp first_non_empty(hints, _fallback) when is_map(hints) and map_size(hints) > 0, do: hints
  defp first_non_empty(_hints, fallback) when is_map(fallback), do: fallback
  defp first_non_empty(_hints, _fallback), do: %{}

  defp candidates_for_hint(_tier, model, adapter, _repo_routing) when is_binary(model), do: [%{adapter: adapter, model: model}]

  defp candidates_for_hint(tier, _model, _adapter, repo_routing) when tier in @tiers do
    repo_candidates(repo_routing, tier) || Map.fetch!(@default_candidates, tier)
  end

  defp candidates_for_hint(_tier, _model, _adapter, _repo_routing), do: []

  defp repo_candidates(repo_routing, tier) when is_map(repo_routing) do
    repo_routing
    |> map_value(:tiers)
    |> case do
      tiers when is_map(tiers) -> Map.get(tiers, tier_key(tier)) || Map.get(tiers, tier)
      _tiers -> nil
    end
    |> normalize_candidates()
  end

  defp repo_candidates(_repo_routing, _tier), do: nil

  defp normalize_candidates(candidates) when is_list(candidates) do
    candidates
    |> Enum.map(fn candidate ->
      %{
        adapter: normalize_adapter(map_value(candidate, :adapter) || map_value(candidate, :agent_adapter)),
        model: normalize_model(map_value(candidate, :model))
      }
    end)
    |> Enum.filter(& &1.model)
    |> case do
      [] -> nil
      normalized -> normalized
    end
  end

  defp normalize_candidates(_candidates), do: nil

  defp repo_floor_tier(repo_routing) when is_map(repo_routing) do
    floor = map_value(repo_routing, :floor)

    if normalize_mode(map_value(floor, :mode), map_value(floor, :required)) == :require do
      normalize_tier(map_value(floor, :tier))
    end
  end

  defp repo_floor_tier(_repo_routing), do: nil

  defp effective_tier(tier, nil), do: tier
  defp effective_tier(nil, floor_tier), do: floor_tier
  defp effective_tier(tier, floor_tier), do: if(tier_rank(tier) < tier_rank(floor_tier), do: floor_tier, else: tier)

  defp floor_fallback?(tier, floor_tier) when is_binary(tier) and is_binary(floor_tier), do: tier_rank(tier) < tier_rank(floor_tier)
  defp floor_fallback?(_tier, _floor_tier), do: false

  defp tier_rank(tier), do: Map.fetch!(@tier_rank, tier)
  defp tier_key("light"), do: :light
  defp tier_key("standard"), do: :standard
  defp tier_key("heavy"), do: :heavy
  defp tier_key("frontier"), do: :frontier

  defp normalize_tier(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if value in @tiers, do: value, else: nil
  end

  defp normalize_tier(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_tier()
  defp normalize_tier(_value), do: nil

  defp normalize_model(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_model(_value), do: nil

  defp normalize_adapter(nil), do: nil

  defp normalize_adapter(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_adapter(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_adapter(_value), do: nil

  defp normalize_mode("require", _required), do: :require
  defp normalize_mode(:require, _required), do: :require
  defp normalize_mode(_mode, true), do: :require
  defp normalize_mode(_mode, _required), do: :prefer

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_value(_map, _key), do: nil

  defp status(_mode, resolved, true) when is_map(resolved), do: :fallback
  defp status(_mode, resolved, _floor_fallback?) when is_map(resolved), do: :honored
  defp status(:require, _resolved, _floor_fallback?), do: :blocked
  defp status(_mode, _resolved, _floor_fallback?), do: :unsupported

  defp reason(_requested_tier, effective_tier, resolved, _mode, true),
    do: "repo require floor #{effective_tier} raised routing to #{resolved.adapter}/#{resolved.model}"

  defp reason(tier, _effective_tier, resolved, _mode, _floor_fallback?) when is_binary(tier) and is_map(resolved),
    do: "resolved tier #{tier} to #{resolved.adapter}/#{resolved.model}"

  defp reason(_tier, _effective_tier, _resolved, :require, _floor_fallback?), do: "required model routing hint could not be honored"
  defp reason(_tier, _effective_tier, _resolved, _mode, _floor_fallback?), do: "no model routing hint resolved"
end
