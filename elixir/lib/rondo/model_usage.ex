defmodule Rondo.ModelUsage do
  @moduledoc """
  Aggregates per-model provider usage mix and model routing timelines
  from orchestrator state (running + archived runs).

  Provides answers to operator questions like:
  - "Which active tickets are consuming Codex subscription right now?"
  - "Did this ticket use Codex before switching to OpenRouter?"
  - Model usage percentages across active and recent runs.
  """

  @type model_key :: String.t()
  @type provider_key :: String.t()
  @type run_entry :: map()
  @type model_usage :: %{
          by_provider: %{provider_key() => provider_usage()},
          by_model: %{model_key() => model_usage()},
          total_runs: non_neg_integer(),
          total_tokens: non_neg_integer(),
          codex_pct: float(),
          openrouter_pct: float()
        }
  @type provider_usage :: %{
          run_count: non_neg_integer(),
          run_pct: float(),
          token_count: non_neg_integer(),
          token_pct: float(),
          models: %{model_key() => %{run_count: non_neg_integer(), token_count: non_neg_integer()}}
        }
  @type timeline_entry :: %{
          at: String.t() | nil,
          adapter: String.t() | nil,
          model: String.t() | nil,
          provider: String.t() | nil,
          status: atom() | String.t(),
          boundary: String.t(),
          reason: String.t() | nil
        }

  @doc """
  Returns aggregated model usage across running and archived runs.

  ## Examples

      iex> ModelUsage.aggregate([], [])
      %{by_provider: %{}, by_model: %{}, total_runs: 0, total_tokens: 0, codex_pct: 0.0, openrouter_pct: 0.0}
  """
  @spec aggregate([run_entry()], [run_entry()]) :: model_usage()
  def aggregate(running, archived) when is_list(running) and is_list(archived) do
    all_runs = running ++ archived
    total_runs = length(all_runs)
    total_tokens = Enum.reduce(all_runs, 0, &(&2 + total_tokens_for_entry(&1)))

    # Build per-model, per-provider maps
    {by_provider, by_model} =
      Enum.reduce(all_runs, {%{}, %{}}, &reduce_run_into_aggregates/2)

    # Compute percentages
    by_provider =
      Map.new(by_provider, fn {provider, usage} ->
        {provider,
         %{
           usage
           | run_pct: pct(usage.run_count, total_runs),
             token_pct: pct(usage.token_count, total_tokens)
         }}
      end)

    # Codex vs OpenRouter subscription impact
    codex_usage = Map.get(by_provider, "codex", %{run_count: 0, token_count: 0})
    openrouter_usage = Map.get(by_provider, "openrouter", %{run_count: 0, token_count: 0})
    codex_pct = pct(codex_usage.run_count, total_runs)
    openrouter_pct = pct(openrouter_usage.run_count, total_runs)

    %{
      by_provider: by_provider,
      by_model: by_model,
      total_runs: total_runs,
      total_tokens: total_tokens,
      codex_pct: Float.round(codex_pct, 1),
      openrouter_pct: Float.round(openrouter_pct, 1)
    }
  end

  @doc """
  Returns which active (running) tickets are consuming a Codex subscription.

  Returns a list of entries with identifier, model, and token count.
  """
  @spec active_codex_consumers([run_entry()]) :: [map()]
  def active_codex_consumers(running) when is_list(running) do
    running
    |> Enum.filter(fn entry ->
      model_info = extract_model_info(entry)
      model_info.provider == "codex" or String.contains?(model_info.model_key || "", "codex")
    end)
    |> Enum.map(fn entry ->
      model_info = extract_model_info(entry)

      %{
        identifier: entry[:identifier] || entry["identifier"],
        model: model_info.model_key,
        provider: model_info.provider,
        tokens: total_tokens_for_entry(entry)
      }
    end)
    |> Enum.sort_by(& &1.identifier)
  end

  @doc """
  Builds a timeline of model routing decisions for a set of runs (typically
  belonging to the same ticket/issue).

  The timeline labels each entry with a boundary:
  - "initial_spawn" — first model selection for the run
  - "continuation" — a subsequent turn in the same run
  - "retry" — a retry attempt
  - "escalation" — model tier raised (e.g. standard → heavy)
  - "review" — review/babysit phase
  - "gate" — gate/repair phase
  - "switch" — provider/model changed from previous

  Returns a chronological list of timeline entries.
  """
  @spec model_timeline([run_entry()]) :: [timeline_entry()]
  def model_timeline(runs) when is_list(runs) do
    runs
    |> Enum.sort_by(&(&1[:started_at] || &1["started_at"] || ""), :asc)
    |> build_timeline([])
    |> Enum.reverse()
  end

  defp build_timeline([], acc), do: acc

  defp build_timeline([run | rest], acc) do
    entries = entries_for_run(run)
    build_timeline(rest, entries ++ acc)
  end

  defp entries_for_run(run) do
    model_info = extract_model_info(run)

    # Try to get model routing history from the event log or stored model_routing
    routing_entries = extract_routing_events(run)

    if routing_entries == [] do
      # Single entry from what we know
      [
        %{
          at: format_ts(run[:started_at] || run["started_at"]),
          adapter: model_info.adapter,
          model: model_info.model,
          provider: model_info.provider,
          status: "active",
          boundary: boundary_for_run(run),
          reason: nil
        }
      ]
    else
      routing_entries
    end
  end

  defp extract_routing_events(run) do
    stored = run[:model_routing] || run["model_routing"]

    if is_map(stored) and map_size(stored) > 0 do
      resolved = stored[:resolved] || stored["resolved"]
      model = resolved_model(resolved)

      [
        %{
          at: format_ts(run[:started_at] || run["started_at"]),
          adapter: resolved_adapter(resolved),
          model: model,
          provider: provider_from_model(model),
          status: stored[:status] || stored["status"],
          boundary: boundary_for_run(run),
          reason: stored[:reason] || stored["reason"]
        }
      ]
    else
      []
    end
  end

  defp resolved_model(resolved) when is_map(resolved),
    do: resolved[:model] || resolved["model"]

  defp resolved_model(_resolved), do: nil

  defp resolved_adapter(resolved) when is_map(resolved),
    do: resolved[:adapter] || resolved["adapter"]

  defp resolved_adapter(_resolved), do: nil

  @doc """
  Distinguishes active model, historical models, fallback candidates, and unused
  configured candidates for a ticket across its runs.

  Returns a map with :active, :historical, :fallback, and :unused keys.
  """
  @spec model_roles([run_entry()]) :: %{
          active: model_info() | nil,
          historical: [model_info()],
          fallback: [model_info()],
          unused: [model_info()]
        }
  def model_roles(runs) when is_list(runs) do
    sorted = Enum.sort_by(runs, &sortable_started_at/1, {:desc, DateTime})
    active = if sorted != [], do: extract_model_info(hd(sorted)), else: nil

    historical =
      sorted
      |> (case sorted do
            [] -> fn _ -> [] end
            [_] -> fn _ -> [] end
            _ -> &tl/1
          end).()
      |> Enum.map(&extract_model_info/1)
      |> Enum.uniq_by(& &1.model_key)

    used_model_keys =
      [active | historical]
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(& &1.model_key)

    fallback_candidates =
      sorted
      |> extract_fallback_candidates()
      |> Enum.reject(&MapSet.member?(used_model_keys, &1.model_key))

    %{
      active: active,
      historical: historical,
      fallback: fallback_candidates,
      unused: []
    }
  end

  defp extract_fallback_candidates(runs) do
    runs
    |> Enum.flat_map(&fallback_candidates_for_run/1)
    |> Enum.uniq_by(& &1.model_key)
  end

  defp fallback_candidates_for_run(run) do
    stored = run[:model_routing] || run["model_routing"]

    if is_map(stored) do
      candidates = stored[:candidates] || stored["candidates"] || []
      resolved = stored[:resolved] || stored["resolved"]
      resolved_model = if is_map(resolved), do: resolved[:model] || resolved["model"]

      candidates
      |> Enum.reject(&candidate_matches?(&1, resolved_model))
      |> Enum.map(&extract_model_info/1)
    else
      []
    end
  end

  defp candidate_matches?(candidate, resolved_model) do
    model = (is_map(candidate) && (candidate[:model] || candidate["model"])) || ""
    model == resolved_model
  end

  # --- Helpers ---

  defp sortable_started_at(run) do
    case run[:started_at] || run["started_at"] do
      %DateTime{} = dt ->
        dt

      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _offset} -> dt
          _ -> ~U[1970-01-01 00:00:00Z]
        end

      _ ->
        ~U[1970-01-01 00:00:00Z]
    end
  end

  defp extract_model_info(entry) when is_map(entry) do
    stored = entry[:model_routing] || entry["model_routing"]

    if is_map(stored) && map_size(stored) > 0 do
      model_info_from_routing(stored)
    else
      model_info_from_entry_fields(entry)
    end
  end

  defp model_info_from_routing(stored) do
    resolved = stored[:resolved] || stored["resolved"]
    adapter = if is_map(resolved), do: resolved[:adapter] || resolved["adapter"]
    model = if is_map(resolved), do: resolved[:model] || resolved["model"]

    %{
      adapter: adapter,
      model: model,
      provider: provider_from_model(model),
      model_key: model_key(adapter, model),
      status: stored[:status] || stored["status"]
    }
  end

  defp model_info_from_entry_fields(entry) do
    adapter = entry[:adapter] || entry["adapter"]
    model = entry[:model] || entry["model"]

    %{
      adapter: adapter,
      model: model,
      provider: provider_from_model(model),
      model_key: model_key(adapter, model),
      status: "unknown"
    }
  end

  @spec total_tokens_for_entry(map()) :: non_neg_integer()
  def total_tokens_for_entry(entry) when is_map(entry) do
    tokens = entry[:tokens] || entry["tokens"]

    if is_map(tokens) and map_size(tokens) > 0 do
      tokens[:total_tokens] || tokens["total_tokens"] || 0
    else
      entry[:claude_total_tokens] || entry["claude_total_tokens"] || 0
    end
  end

  @doc false
  @spec provider_from_model(String.t() | nil) :: String.t() | nil
  def provider_from_model(nil), do: nil

  def provider_from_model(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "openai-codex/") -> "codex"
      String.starts_with?(model, "openrouter/") -> "openrouter"
      String.starts_with?(model, "openai/") -> "openai"
      String.starts_with?(model, "anthropic/") -> "anthropic"
      String.contains?(model, "codex") -> "codex"
      String.contains?(model, "openrouter") -> "openrouter"
      true -> nil
    end
  end

  @doc false
  @spec model_key(String.t() | nil, String.t() | nil) :: String.t() | nil
  def model_key(adapter, model) do
    cond do
      is_binary(model) -> model
      is_binary(adapter) -> "adapter:#{adapter}"
      true -> nil
    end
  end

  defp reduce_run_into_aggregates(entry, {providers, models}) do
    model_info = extract_model_info(entry)
    provider = model_info.provider
    model_key = model_info.model_key

    providers =
      if provider do
        Map.update(providers, provider, new_provider_entry(entry, model_info), fn p ->
          update_provider_entry(p, entry, model_key || "unknown")
        end)
      else
        providers
      end

    models =
      if model_key do
        Map.update(
          models,
          model_key,
          %{run_count: 1, token_count: total_tokens_for_entry(entry), provider: provider},
          &update_model_entry(&1, entry)
        )
      else
        models
      end

    {providers, models}
  end

  defp new_provider_entry(entry, model_info) do
    %{
      run_count: 1,
      run_pct: 0.0,
      token_count: total_tokens_for_entry(entry),
      token_pct: 0.0,
      models: %{
        (model_info.model_key || "unknown") => %{run_count: 1, token_count: total_tokens_for_entry(entry)}
      }
    }
  end

  defp update_provider_entry(p, entry, model_key) do
    token_count = total_tokens_for_entry(entry)

    %{
      p
      | run_count: p.run_count + 1,
        token_count: p.token_count + token_count,
        models: Map.update(p.models, model_key, %{run_count: 1, token_count: token_count}, &increment_model_counts(&1, token_count))
    }
  end

  defp increment_model_counts(model, tokens) do
    %{model | run_count: model.run_count + 1, token_count: model.token_count + tokens}
  end

  defp update_model_entry(m, entry) do
    tokens = total_tokens_for_entry(entry)
    %{m | run_count: m.run_count + 1, token_count: m.token_count + tokens}
  end

  defp pct(0, 0), do: 0.0
  defp pct(part, total), do: Float.round(part / total * 100.0, 1)

  defp boundary_for_run(run) do
    exit_reason = run[:exit_reason] || run["exit_reason"]

    cond do
      terminal_boundary?(exit_reason) -> exit_reason_boundary(exit_reason)
      exited_boundary?(exit_reason) -> "retry"
      retry_attempt?(run) -> "retry"
      fresh_run?(run) -> "active"
      true -> "initial_spawn"
    end
  end

  defp terminal_boundary?(r) when r in ["completed", "terminated", "failed"], do: true
  defp terminal_boundary?(_r), do: false

  defp exit_reason_boundary("completed"), do: "completed"
  defp exit_reason_boundary(_r), do: "terminated"

  defp exited_boundary?(r) when is_binary(r), do: String.starts_with?(r, "exited")
  defp exited_boundary?(_r), do: false

  defp retry_attempt?(run) do
    (run[:retry_attempt] || run["retry_attempt"] || 0) > 0
  end

  defp fresh_run?(run),
    do: run[:started_at] == nil and run["started_at"] == nil

  defp format_ts(nil), do: nil
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(ts) when is_binary(ts), do: ts

  @type model_info :: %{
          adapter: String.t() | nil,
          model: String.t() | nil,
          provider: String.t() | nil,
          model_key: String.t() | nil,
          status: atom() | String.t() | nil
        }
end
