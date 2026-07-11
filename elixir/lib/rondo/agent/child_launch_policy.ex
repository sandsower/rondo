defmodule Rondo.Agent.ChildLaunchPolicy do
  @moduledoc """
  Compiles trusted runtime policy and untrusted source restrictions into one
  fail-closed child-launch envelope.

  This module does not claim same-user credential isolation. Environment and
  synthetic-home scoping are foundations. Unattended execution additionally
  requires an OS-enforced credential-isolation baseline.
  """

  alias Rondo.Agent.ChildLaunchEnvelope

  @required_isolation_baseline :os_credential_isolated
  @isolation_ranks %{none: 0, env_home_scoped: 1, os_credential_isolated: 2}
  @valid_run_modes ["supervised-auto", "unattended-auto"]
  @valid_origins [:daemon, :http, :manifest, :run_once]
  @action_keys ~w(run_mode allow ask deny)
  @operational_env_names ~w(PATH LANG LC_ALL LC_CTYPE TERM SHELL TMPDIR)
  @forbidden_env_patterns [
    ~r/LINEAR/i,
    ~r/^GH_/i,
    ~r/GITHUB/i,
    ~r/SSH/i,
    ~r/MCP/i,
    ~r/AWS/i,
    ~r/AZURE/i,
    ~r/GOOGLE.*(?:TOKEN|KEY|CREDENTIAL)/i,
    ~r/(?:TOKEN|SECRET|PASSWORD|CREDENTIAL)/i
  ]

  @type resolution :: {:ok, ChildLaunchEnvelope.t()} | {:block, ChildLaunchEnvelope.t()}

  @spec resolve(keyword()) :: resolution()
  def resolve(opts) when is_list(opts) do
    inherited_env = Keyword.get(opts, :inherited_env, System.get_env())
    run_mode = Keyword.get(opts, :run_mode, "unattended-auto")
    origin = Keyword.get(opts, :dispatch_origin, :daemon)
    adapter = Keyword.fetch!(opts, :adapter)
    model = Keyword.get(opts, :model)
    source_contract = Keyword.get(opts, :source_contract, %{}) || %{}
    isolation_baseline = Keyword.get(opts, :isolation_baseline, :env_home_scoped)
    unsafe_bypass = Keyword.get(opts, :unsafe_bypass, false)
    run_dir = Keyword.fetch!(opts, :run_dir)

    with :ok <- validate_host_inputs(run_mode, origin, isolation_baseline, adapter, run_dir, inherited_env),
         {:ok, requested_actions} <- requested_actions(source_contract),
         {:ok, provider_env_names, model_provider} <- provider_environment_names(adapter, model, opts) do
      effective_actions = effective_actions(requested_actions)
      environment = scoped_environment(inherited_env, provider_env_names, run_dir, adapter)
      source_contract_digest = source_contract_digest(source_contract)

      envelope =
        build_envelope(%{
          run_mode: run_mode,
          origin: origin,
          adapter: adapter,
          model_provider: model_provider,
          source_contract_digest: source_contract_digest,
          requested_actions: requested_actions,
          effective_actions: effective_actions,
          isolation_baseline: isolation_baseline,
          environment: environment,
          run_dir: run_dir,
          unsafe_bypass: unsafe_bypass
        })

      resolution(envelope)
    else
      {:error, reason} ->
        envelope = invalid_envelope(opts, run_mode, origin, adapter, model, isolation_baseline, run_dir, reason)
        {:block, envelope}
    end
  end

  @spec sanitize(ChildLaunchEnvelope.t()) :: map()
  def sanitize(envelope), do: ChildLaunchEnvelope.sanitized(envelope)

  defp validate_host_inputs(run_mode, origin, isolation_baseline, adapter, run_dir, inherited_env) do
    with :ok <- validate_member(run_mode, @valid_run_modes, :invalid_run_mode),
         :ok <- validate_member(origin, @valid_origins, :invalid_dispatch_origin),
         :ok <- validate_isolation_baseline(isolation_baseline),
         :ok <- validate_nonempty_string(adapter, :invalid_adapter),
         :ok <- validate_nonempty_string(run_dir, :invalid_run_dir) do
      validate_environment(inherited_env)
    end
  end

  defp validate_member(value, allowed, reason) do
    if value in allowed, do: :ok, else: {:error, reason}
  end

  defp validate_isolation_baseline(baseline) do
    if Map.has_key?(@isolation_ranks, baseline), do: :ok, else: {:error, :invalid_isolation_baseline}
  end

  defp validate_nonempty_string(value, reason) when is_binary(value) do
    if String.trim(value) == "", do: {:error, reason}, else: :ok
  end

  defp validate_nonempty_string(_value, reason), do: {:error, reason}

  defp validate_environment(environment) when is_map(environment) do
    if Enum.all?(environment, fn {name, value} -> is_binary(name) and is_binary(value) end) do
      :ok
    else
      {:error, :invalid_inherited_environment}
    end
  end

  defp validate_environment(_environment), do: {:error, :invalid_inherited_environment}

  defp requested_actions(source_contract) when is_map(source_contract) do
    case Map.get(source_contract, :allowed_actions) || Map.get(source_contract, "allowed_actions") do
      nil -> {:ok, %{}}
      value when is_map(value) -> validate_requested_actions(value)
      _other -> {:error, :invalid_allowed_actions}
    end
  end

  defp requested_actions(_source_contract), do: {:error, :invalid_source_contract}

  defp validate_requested_actions(actions) do
    normalized = Map.new(actions, fn {key, value} -> {to_string(key), value} end)
    unknown_keys = Map.keys(normalized) -- @action_keys

    cond do
      unknown_keys != [] ->
        {:error, :invalid_allowed_actions}

      not valid_optional_string?(Map.get(normalized, "run_mode")) ->
        {:error, :invalid_allowed_actions}

      Enum.any?(~w(allow ask deny), &(not valid_action_list?(Map.get(normalized, &1)))) ->
        {:error, :invalid_allowed_actions}

      true ->
        {:ok, normalized}
    end
  end

  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_action_list?(nil), do: true
  defp valid_action_list?(values), do: is_list(values) and Enum.all?(values, &(is_binary(&1) and String.trim(&1) != ""))

  defp effective_actions(requested_actions) do
    denied = Map.get(requested_actions, "deny", [])

    %{
      local_worktree_write: not denied_action?(denied, ["workspace.write", "file.write"]),
      local_git_write: not denied_action?(denied, ["git.commit", "git.local"]),
      publication: false,
      tracker: false,
      mcp: false
    }
  end

  defp denied_action?(denied, candidates), do: Enum.any?(candidates, &(&1 in denied))

  defp provider_environment_names(adapter, model, opts) do
    case Keyword.get(opts, :provider_auth_env_names) do
      names when is_list(names) ->
        validate_provider_env_names(names, provider_from_model(adapter, model))

      nil ->
        provider = provider_from_model(adapter, model)
        validate_provider_env_names(default_provider_env_names(adapter, provider), provider)

      _other ->
        {:error, :invalid_provider_auth_profile}
    end
  end

  defp validate_provider_env_names(names, provider) do
    if Enum.all?(names, &(is_binary(&1) and provider_auth_name?(&1))) do
      {:ok, Enum.uniq(names), provider}
    else
      {:error, :invalid_provider_auth_profile}
    end
  end

  defp provider_auth_name?(name) do
    name in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"]
  end

  defp default_provider_env_names("claude_code", _provider), do: ["ANTHROPIC_API_KEY"]
  defp default_provider_env_names("codex", _provider), do: ["OPENAI_API_KEY"]
  defp default_provider_env_names("pi", "openrouter"), do: ["OPENROUTER_API_KEY"]
  defp default_provider_env_names("pi", provider) when provider in ["openai", "openai-codex"], do: ["OPENAI_API_KEY"]
  defp default_provider_env_names("pi", "anthropic"), do: ["ANTHROPIC_API_KEY"]
  defp default_provider_env_names(_adapter, _provider), do: []

  defp provider_from_model(_adapter, model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, _model] -> provider
      [_model] -> "native"
    end
  end

  defp provider_from_model(adapter, _model), do: adapter

  defp scoped_environment(inherited_env, provider_env_names, run_dir, adapter) do
    operational = Map.take(inherited_env, @operational_env_names)
    provider = Map.take(inherited_env, provider_env_names)

    operational
    |> Map.merge(provider)
    |> Map.reject(fn {name, _value} -> forbidden_non_provider_name?(name, provider_env_names) end)
    |> Map.put("HOME", synthetic_home(run_dir, adapter))
    |> Map.put("TMPDIR", Path.join(synthetic_home(run_dir, adapter), "tmp"))
    |> Map.put("GIT_CONFIG_GLOBAL", "/dev/null")
    |> Map.put("GIT_CONFIG_NOSYSTEM", "1")
    |> Map.put("GIT_TERMINAL_PROMPT", "0")
    |> Map.put("GH_CONFIG_DIR", Path.join(synthetic_home(run_dir, adapter), ".config/gh"))
  end

  defp forbidden_non_provider_name?(name, provider_env_names) do
    name not in provider_env_names and Enum.any?(@forbidden_env_patterns, &Regex.match?(&1, name))
  end

  defp synthetic_home(run_dir, adapter), do: Path.join([run_dir, "child-home", safe_segment(adapter)])

  defp safe_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim("-")
  end

  defp build_envelope(%{
         run_mode: run_mode,
         origin: origin,
         adapter: adapter,
         model_provider: model_provider,
         source_contract_digest: source_contract_digest,
         requested_actions: requested_actions,
         effective_actions: effective_actions,
         isolation_baseline: isolation_baseline,
         environment: environment,
         run_dir: run_dir,
         unsafe_bypass: unsafe_bypass
       }) do
    {decision, reason, bypass} = launch_decision(run_mode, origin, isolation_baseline, unsafe_bypass)

    struct!(ChildLaunchEnvelope,
      decision: decision,
      reason: reason,
      run_mode: run_mode,
      dispatch_origin: origin,
      adapter: adapter,
      model_provider: model_provider,
      source_contract_digest: source_contract_digest,
      requested_actions: requested_actions,
      effective_actions: effective_actions,
      isolation_baseline: isolation_baseline,
      required_isolation_baseline: @required_isolation_baseline,
      home_path: synthetic_home(run_dir, adapter),
      environment: environment,
      bypass: bypass,
      credential_classes: [:provider_auth]
    )
  end

  defp launch_decision(run_mode, origin, isolation_baseline, unsafe_bypass) do
    cond do
      sufficient_isolation?(isolation_baseline) ->
        {:allow, :isolation_satisfied, %{requested: unsafe_bypass, applied: false, reason: :not_needed}}

      unsafe_bypass and run_mode == "supervised-auto" and origin == :run_once ->
        bypass = %{requested: true, applied: true, reason: :explicit_supervised_run_once}
        {:supervised_bypass, :explicit_supervised_run_once_bypass, bypass}

      true ->
        {:block, :insufficient_isolation, %{requested: unsafe_bypass, applied: false, reason: :not_permitted}}
    end
  end

  defp sufficient_isolation?(baseline) do
    Map.fetch!(@isolation_ranks, baseline) >= Map.fetch!(@isolation_ranks, @required_isolation_baseline)
  end

  defp resolution(%ChildLaunchEnvelope{decision: :block} = envelope), do: {:block, envelope}
  defp resolution(%ChildLaunchEnvelope{} = envelope), do: {:ok, envelope}

  defp invalid_envelope(opts, run_mode, origin, adapter, model, isolation_baseline, run_dir, reason) do
    denied_actions = %{
      local_worktree_write: false,
      local_git_write: false,
      publication: false,
      tracker: false,
      mcp: false
    }

    struct!(ChildLaunchEnvelope,
      decision: :block,
      reason: reason,
      run_mode: run_mode,
      dispatch_origin: origin,
      adapter: adapter,
      model_provider: provider_from_model(adapter, model),
      isolation_baseline: isolation_baseline,
      required_isolation_baseline: @required_isolation_baseline,
      home_path: invalid_home_path(run_dir, adapter),
      environment: %{},
      effective_actions: denied_actions,
      bypass: %{requested: Keyword.get(opts, :unsafe_bypass, false), applied: false, reason: :invalid_request}
    )
  end

  defp invalid_home_path(run_dir, adapter)
       when is_binary(run_dir) and run_dir != "" and is_binary(adapter) and adapter != "" do
    synthetic_home(run_dir, adapter)
  end

  defp invalid_home_path(_run_dir, _adapter), do: nil

  defp source_contract_digest(source_contract) when source_contract == %{}, do: nil

  defp source_contract_digest(source_contract) do
    source_contract
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
