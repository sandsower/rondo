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
          reason: String.t(),
          profile: String.t() | nil
        }

  @openrouter_env "OPENROUTER_API_KEY"

  @spec resolve(keyword()) :: routing_status()
  def resolve(opts \\ []) when is_list(opts) do
    repo_routing = Keyword.get_lazy(opts, :repo_model_routing, &Config.model_routing/0)
    routing_context = normalize_routing_context(Keyword.get(opts, :routing_context, %{}))
    profile_name = Keyword.get(opts, :routing_profile)
    {hints, context} = effective_hints(opts, repo_routing, routing_context, profile_name)
    requested_tier = normalize_tier(map_value(hints, :tier))
    floor_tier = repo_floor_tier(repo_routing)
    effective_tier = effective_tier(requested_tier, floor_tier)
    model = normalize_model(map_value(hints, :model)) || normalize_model(map_value(hints, :claude_model))
    adapter = normalize_adapter(map_value(hints, :agent_adapter)) || normalize_adapter(map_value(hints, :adapter))
    mode = normalize_mode(map_value(hints, :mode), map_value(hints, :required))
    candidates = candidates_for_hint(effective_tier, model, adapter, repo_routing, Map.get(hints, :required_unresolved))
    {candidates, openrouter_credentials_missing?} = filter_openrouter_candidates(candidates)
    resolved = List.first(candidates)
    floor_fallback? = floor_fallback?(requested_tier, floor_tier)

    result = %{
      status: status(mode, resolved, floor_fallback?),
      mode: mode,
      requested_tier: requested_tier,
      candidates: candidates,
      resolved: resolved,
      reason: reason(requested_tier, effective_tier, resolved, mode, floor_fallback?, context)
    }

    result
    |> maybe_apply_credential_failure(openrouter_credentials_missing?, mode, context)
    |> maybe_put_context(context)
    |> maybe_put_profile(profile_name)
  end

  defp effective_hints(opts, repo_routing, routing_context, profile_name) do
    provider_hint_map = Keyword.get(opts, :model_routing_hints, %{}) || %{}
    source_hint_map = source_contract_hints(opts)
    repo_step_hint_map = repo_step_hints(repo_routing)
    profile_defaults = profile_default_hints(repo_routing, profile_name)

    provider_context_hints = context_specific_hints(provider_hint_map, routing_context)
    repo_step_context_hints = context_specific_hints(repo_step_hint_map, routing_context)
    source_context_hints = context_specific_hints(source_hint_map, routing_context)
    context_hints = source_context_hints || provider_context_hints || repo_step_context_hints
    context_hint_map = normalize_hint_map(context_hints || %{})

    hints =
      repo_routing
      |> repo_default_hints()
      |> apply_hint_map(profile_defaults)
      |> apply_hint_map(provider_hint_map)
      |> maybe_clear_broad_model_for_context(context_hint_map)
      |> apply_hint_map(repo_step_context_hints || %{})
      |> apply_hint_map(provider_context_hints || %{})
      |> apply_hint_map(source_hint_map)
      |> apply_hint_map(source_context_hints || %{})

    {hints, normalize_context_metadata(context_hints, routing_context)}
  end

  defp repo_default_hints(repo_routing) when is_map(repo_routing) do
    repo_routing
    |> map_value(:defaults)
    |> normalize_hint_map()
  end

  defp repo_default_hints(_repo_routing), do: %{}

  defp repo_step_hints(repo_routing) when is_map(repo_routing) do
    repo_routing
    |> map_value(:step_hints)
    |> map_or_empty()
  end

  defp repo_step_hints(_repo_routing), do: %{}

  defp profile_default_hints(repo_routing, profile_name)
       when is_binary(profile_name) or is_atom(profile_name) do
    repo_routing
    |> map_value(:profiles)
    |> profile_lookup(profile_name)
    |> normalize_hint_map()
  end

  defp profile_default_hints(_repo_routing, _profile_name), do: %{}

  defp profile_lookup(profiles, name) when is_map(profiles) and is_atom(name) do
    Map.get(profiles, name) || Map.get(profiles, Atom.to_string(name))
  end

  defp profile_lookup(profiles, name) when is_map(profiles) and is_binary(name) do
    Map.get(profiles, name) ||
      if String.printable?(name), do: Map.get(profiles, String.to_atom(name)), else: nil
  end

  defp profile_lookup(_profiles, _name), do: nil

  defp source_contract_hints(opts) do
    source_contract = Keyword.get(opts, :source_contract, %{})

    source_contract
    |> source_contract_runner_extension_hints()
    |> Map.merge(source_contract_model_routing_hints(source_contract))
    |> Map.merge(source_contract_direct_hints(source_contract))
  end

  defp source_contract_runner_extension_hints(source_contract) do
    source_contract
    |> map_value(:runner_extensions)
    |> map_value(:model_routing)
    |> map_or_empty()
  end

  defp source_contract_model_routing_hints(source_contract) do
    source_contract
    |> map_value(:model_routing_hints)
    |> map_or_empty()
  end

  defp source_contract_direct_hints(source_contract) do
    source_contract
    |> map_value(:model_routing)
    |> map_or_empty()
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp normalize_hint_map(hints) when is_map(hints) do
    %{}
    |> put_normalized_hint(:adapter, normalize_adapter(map_value(hints, :adapter)))
    |> put_normalized_hint(:agent_adapter, normalize_adapter(map_value(hints, :agent_adapter)))
    |> put_normalized_hint(:claude_model, normalize_model(map_value(hints, :claude_model)))
    |> put_normalized_hint(:model, normalize_model(map_value(hints, :model)))
    |> put_normalized_hint(:mode, normalize_mode_value(map_value(hints, :mode)))
    |> put_normalized_hint(:required, normalize_required(map_value(hints, :required)))
    |> put_normalized_hint(:tier, normalize_tier(map_value(hints, :tier) || map_value(hints, :capability_tier)))
  end

  defp normalize_hint_map(_hints), do: %{}

  defp apply_hint_map(hints, hint_map) do
    normalized = normalize_hint_map(hint_map)

    cond do
      required_unresolved_hint?(hint_map, normalized) ->
        hints
        |> Map.drop([:tier, :model, :claude_model])
        |> Map.merge(Map.put(normalized, :required_unresolved, true))

      routing_hint?(normalized) ->
        hints
        |> Map.delete(:required_unresolved)
        |> Map.merge(normalized)

      true ->
        Map.merge(hints, normalized)
    end
  end

  defp required_unresolved_hint?(hint_map, normalized) when is_map(hint_map) do
    normalize_mode(map_value(hint_map, :mode), map_value(hint_map, :required)) == :require and
      raw_routing_hint?(hint_map) and not routing_hint?(normalized)
  end

  defp required_unresolved_hint?(_hint_map, _normalized), do: false

  defp raw_routing_hint?(hint_map) do
    Enum.any?([:tier, :capability_tier, :model, :claude_model], &(not is_nil(map_value(hint_map, &1))))
  end

  defp routing_hint?(hint_map) when is_map(hint_map) do
    Enum.any?([:tier, :model, :claude_model], &(not is_nil(map_value(hint_map, &1))))
  end

  defp context_specific_hints(_hints, context) when map_size(context) == 0, do: nil

  defp context_specific_hints(hints, %{stage: "initial_spawn"} = context) when is_map(hints) do
    direct_context_hints(hints, [:initial_spawn, :initial]) || matching_context_hints(hints, context) ||
      unambiguous_stage_less_context_hints(hints)
  end

  defp context_specific_hints(hints, context) when is_map(hints), do: matching_context_hints(hints, context)
  defp context_specific_hints(_hints, _context), do: nil

  defp direct_context_hints(hints, keys) do
    keys
    |> Enum.map(&map_value(hints, &1))
    |> Enum.find(&is_map/1)
  end

  defp matching_context_hints(hints, context) do
    [:steps, :phases]
    |> Enum.map(&map_value(hints, &1))
    |> Enum.find_value(fn
      entries when is_list(entries) -> Enum.find(entries, &context_hint_matches?(&1, context))
      _entries -> nil
    end)
  end

  defp unambiguous_stage_less_context_hints(hints) do
    candidates =
      [:steps, :phases]
      |> Enum.flat_map(fn key ->
        case map_value(hints, key) do
          entries when is_list(entries) -> Enum.filter(entries, &stage_less_context_hint?/1)
          _entries -> []
        end
      end)

    case candidates do
      [hint] -> hint
      _ambiguous_or_absent -> nil
    end
  end

  defp stage_less_context_hint?(hint) when is_map(hint) do
    is_nil(normalize_context_value(map_value(hint, :stage))) and
      Enum.any?([:skill, :phase, :step], &(not is_nil(normalize_context_value(map_value(hint, &1)))))
  end

  defp stage_less_context_hint?(_hint), do: false

  defp context_hint_matches?(hint, context) when is_map(hint) do
    selectors =
      [:stage, :skill, :phase, :step]
      |> Enum.map(fn key -> {key, normalize_context_value(map_value(hint, key))} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    selectors != [] and
      Enum.all?(selectors, fn {key, hint_value} ->
        normalize_context_value(map_value(context, key)) == hint_value
      end)
  end

  defp context_hint_matches?(_hint, _context), do: false

  defp normalize_context_metadata(nil, _routing_context), do: nil

  defp normalize_context_metadata(hints, routing_context) when is_map(hints) do
    [:stage, :skill, :phase, :step]
    |> Enum.reduce(%{}, fn key, acc ->
      value = normalize_context_value(map_value(hints, key) || map_value(routing_context, key))
      if value, do: Map.put(acc, key, value), else: acc
    end)
  end

  defp normalize_routing_context(context) when is_map(context) do
    [:stage, :skill, :phase, :step]
    |> Enum.reduce(%{}, fn key, acc ->
      value = normalize_context_value(map_value(context, key))
      if value, do: Map.put(acc, key, value), else: acc
    end)
  end

  defp normalize_routing_context(_context), do: %{}

  defp normalize_context_value(nil), do: nil
  defp normalize_context_value(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_context_value()

  defp normalize_context_value(value) when is_binary(value) do
    value = String.trim(value) |> String.downcase()

    case value do
      "" -> nil
      trimmed -> Regex.replace(~r/[-\s_]+/, trimmed, "_")
    end
  end

  defp normalize_context_value(_value), do: nil

  defp maybe_put_context(result, nil), do: result
  defp maybe_put_context(result, context), do: Map.put(result, :context, context)

  defp maybe_put_profile(result, nil), do: result
  defp maybe_put_profile(result, profile_name), do: Map.put(result, :profile, profile_name)

  defp maybe_clear_broad_model_for_context(hints, %{tier: _tier} = context_hints) do
    if Map.has_key?(context_hints, :model) or Map.has_key?(context_hints, :claude_model) do
      hints
    else
      Map.drop(hints, [:model, :claude_model])
    end
  end

  defp maybe_clear_broad_model_for_context(hints, _context_hints), do: hints

  defp put_normalized_hint(hints, _key, nil), do: hints
  defp put_normalized_hint(hints, key, value), do: Map.put(hints, key, value)

  defp candidates_for_hint(_tier, _model, _adapter, _repo_routing, true), do: []
  defp candidates_for_hint(_tier, model, adapter, _repo_routing, _required_unresolved) when is_binary(model), do: [%{adapter: adapter, model: model}]

  defp candidates_for_hint(tier, _model, _adapter, repo_routing, _required_unresolved) when tier in @tiers do
    repo_candidates(repo_routing, tier) || Map.fetch!(@default_candidates, tier)
  end

  defp candidates_for_hint(_tier, _model, _adapter, _repo_routing, _required_unresolved), do: []

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

  defp filter_openrouter_candidates(candidates) do
    openrouter_key_available? = openrouter_key_available?()

    {available, removed} =
      Enum.split_with(candidates, fn candidate ->
        not openrouter_candidate?(candidate) or openrouter_key_available?
      end)

    {available, removed != [] and not openrouter_key_available?}
  end

  defp openrouter_candidate?(%{model: model}) when is_binary(model) do
    String.starts_with?(model, "openrouter/")
  end

  defp openrouter_key_available? do
    case System.get_env(@openrouter_env) do
      nil -> false
      "" -> false
      _value -> true
    end
  end

  defp maybe_apply_credential_failure(%{resolved: resolved} = result, true, mode, context)
       when is_nil(resolved) do
    reason = "OpenRouter API key missing; cannot resolve #{context_label(context)}OpenRouter candidate"
    %{result | status: credential_status(mode), reason: reason}
  end

  defp maybe_apply_credential_failure(result, _missing?, _mode, _context), do: result

  defp credential_status(:require), do: :blocked
  defp credential_status(_mode), do: :unsupported

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

  defp normalize_mode_value("require"), do: "require"
  defp normalize_mode_value(:require), do: :require
  defp normalize_mode_value("prefer"), do: "prefer"
  defp normalize_mode_value(:prefer), do: :prefer
  defp normalize_mode_value(_mode), do: nil

  defp normalize_required(value) when is_boolean(value), do: value
  defp normalize_required(_value), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_value(_map, _key), do: nil

  defp status(_mode, resolved, true) when is_map(resolved), do: :fallback
  defp status(_mode, resolved, _floor_fallback?) when is_map(resolved), do: :honored
  defp status(:require, _resolved, _floor_fallback?), do: :blocked
  defp status(_mode, _resolved, _floor_fallback?), do: :unsupported

  defp reason(_requested_tier, effective_tier, resolved, _mode, true, context),
    do: "repo require floor #{effective_tier} raised #{context_label(context)}routing to #{candidate_label(resolved)}"

  defp reason(tier, _effective_tier, resolved, _mode, _floor_fallback?, context) when is_binary(tier) and is_map(resolved),
    do: "resolved #{context_label(context)}tier #{tier} to #{candidate_label(resolved)}"

  defp reason(_tier, _effective_tier, resolved, _mode, _floor_fallback?, context) when is_map(resolved),
    do: "resolved #{context_label(context)}explicit model to #{candidate_label(resolved)}"

  defp reason(_tier, _effective_tier, _resolved, :require, _floor_fallback?, context),
    do: "required #{context_label(context)}model routing hint could not be honored"

  defp reason(_tier, _effective_tier, _resolved, _mode, _floor_fallback?, context),
    do: "no #{context_label(context)}model routing hint resolved"

  defp context_label(nil), do: ""

  defp context_label(context) when is_map(context) do
    parts =
      [:stage, :skill, :phase, :step]
      |> Enum.map(&Map.get(context, &1))
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "/") <> " "
  end

  defp candidate_label(%{adapter: adapter, model: model}) when is_binary(adapter), do: "#{adapter}/#{model}"
  defp candidate_label(%{model: model}), do: model
end
