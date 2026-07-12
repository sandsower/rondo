defmodule Rondo.ChildLaunchPolicyTest do
  use ExUnit.Case, async: true

  alias Rondo.Agent.ChildLaunchPolicy

  @secret "top-secret-value"

  test "unattended launch fails closed without OS credential isolation" do
    assert {:block, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "unattended-auto",
               dispatch_origin: :daemon,
               adapter: "pi",
               model: "openrouter/deepseek/deepseek-chat",
               isolation_baseline: :env_home_scoped,
               run_dir: "/tmp/run-1",
               inherited_env: %{"LINEAR_API_KEY" => @secret, "OPENROUTER_API_KEY" => @secret}
             )

    assert envelope.decision == :block
    assert envelope.reason == :insufficient_isolation
    assert envelope.required_isolation_baseline == :os_credential_isolated
    assert envelope.environment == %{}
    refute inspect(ChildLaunchPolicy.sanitize(envelope)) =~ @secret
  end

  test "supervised run-once may use an explicit, ledger-visible bypass" do
    assert {:ok, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "supervised-auto",
               dispatch_origin: :run_once,
               unsafe_bypass: true,
               adapter: "codex",
               model: "gpt-5.4",
               isolation_baseline: :env_home_scoped,
               run_dir: "/tmp/run-2",
               inherited_env: %{"OPENAI_API_KEY" => @secret, "GH_TOKEN" => @secret}
             )

    assert envelope.decision == :supervised_bypass
    assert envelope.bypass == %{requested: true, attempted: true, applied: true, reason: :explicit_supervised_run_once}
    assert envelope.environment["OPENAI_API_KEY"] == @secret
    refute Map.has_key?(envelope.environment, "GH_TOKEN")
    refute inspect(ChildLaunchPolicy.sanitize(envelope)) =~ @secret
  end

  test "bypass is unreachable from unattended, daemon, and HTTP dispatch" do
    for {run_mode, origin} <- [
          {"unattended-auto", :run_once},
          {"supervised-auto", :daemon},
          {"supervised-auto", :http}
        ] do
      assert {:block, envelope} =
               ChildLaunchPolicy.resolve(
                 run_mode: run_mode,
                 dispatch_origin: origin,
                 unsafe_bypass: true,
                 adapter: "claude_code",
                 model: "claude-sonnet",
                 isolation_baseline: :env_home_scoped,
                 run_dir: "/tmp/run-3",
                 inherited_env: %{"ANTHROPIC_API_KEY" => @secret}
               )

      refute envelope.bypass.applied
    end
  end

  test "manifest source provenance overrides a claimed run-once origin and rejects bypass" do
    source_contract = %{
      schema: "rondo-execution-request-v1",
      slice_id: "slice-review",
      path: "/tmp/review-manifest.json",
      sha256: String.duplicate("a", 64)
    }

    assert {:block, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "supervised-auto",
               dispatch_origin: :run_once,
               unsafe_bypass: true,
               adapter: "pi",
               model: "openrouter/deepseek/deepseek-chat",
               isolation_baseline: :os_credential_isolated,
               run_dir: "/tmp/run-manifest-origin",
               source_contract: source_contract,
               inherited_env: %{}
             )

    assert envelope.dispatch_origin == :manifest
    assert envelope.reason == :manifest_child_credential_bypass_forbidden
    refute envelope.bypass.applied
    assert envelope.environment == %{}
  end

  test "manifest actions can narrow but cannot grant publication, tracker, or MCP authority" do
    source_contract = %{
      allowed_actions: %{
        "run_mode" => "supervised-auto",
        "allow" => ["git.push", "tracker.issue.transition", "mcp.call", "workspace.write"],
        "deny" => ["git.commit"]
      }
    }

    assert {:ok, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "unattended-auto",
               dispatch_origin: :manifest,
               adapter: "pi",
               model: "openrouter/deepseek/deepseek-chat",
               isolation_baseline: :os_credential_isolated,
               run_dir: "/tmp/run-4",
               source_contract: source_contract,
               inherited_env: %{"OPENROUTER_API_KEY" => @secret}
             )

    refute envelope.effective_actions.publication
    refute envelope.effective_actions.tracker
    refute envelope.effective_actions.mcp
    refute envelope.effective_actions.local_git_write
    assert envelope.effective_actions.local_worktree_write
    assert envelope.run_mode == "unattended-auto"
  end

  test "unknown manifest action shapes fail closed" do
    assert {:block, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "unattended-auto",
               dispatch_origin: :manifest,
               adapter: "pi",
               model: "openrouter/deepseek/deepseek-chat",
               isolation_baseline: :os_credential_isolated,
               run_dir: "/tmp/run-5",
               source_contract: %{allowed_actions: "everything"},
               inherited_env: %{}
             )

    assert envelope.reason == :invalid_allowed_actions
  end

  test "provider credential overrides must match the selected provider" do
    assert {:block, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "unattended-auto",
               dispatch_origin: :daemon,
               adapter: "claude_code",
               model: "claude-sonnet",
               isolation_baseline: :os_credential_isolated,
               run_dir: "/tmp/run-provider-mismatch",
               provider_auth_env_names: ["OPENAI_API_KEY"],
               inherited_env: %{"ANTHROPIC_API_KEY" => @secret, "OPENAI_API_KEY" => @secret}
             )

    assert envelope.reason == :invalid_provider_auth_profile
    assert envelope.environment == %{}
  end

  test "unsupported adapter provider profiles fail closed" do
    examples = [
      [adapter: "pi"],
      [adapter: "unknown", model: "openrouter/example"],
      [adapter: "claude_code", model: "openai/example"]
    ]

    for adapter_opts <- examples do
      assert {:block, envelope} =
               ChildLaunchPolicy.resolve(
                 [
                   run_mode: "unattended-auto",
                   dispatch_origin: :daemon,
                   isolation_baseline: :os_credential_isolated,
                   run_dir: "/tmp/run-provider-unsupported",
                   inherited_env: %{}
                 ] ++ adapter_opts
               )

      assert envelope.reason == :invalid_provider_auth_profile
      assert envelope.environment == %{}
    end
  end

  test "malformed launch paths fail closed instead of raising" do
    assert {:block, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "unattended-auto",
               dispatch_origin: :daemon,
               adapter: "pi",
               isolation_baseline: :os_credential_isolated,
               run_dir: nil,
               inherited_env: %{}
             )

    assert envelope.reason == :invalid_run_dir
    assert envelope.environment == %{}
  end

  test "sanitized evidence does not echo untrusted action values" do
    source_contract = %{allowed_actions: %{"allow" => ["workspace.write.#{@secret}"]}}

    assert {:ok, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "unattended-auto",
               dispatch_origin: :manifest,
               adapter: "pi",
               model: "openrouter/deepseek/deepseek-chat",
               isolation_baseline: :os_credential_isolated,
               run_dir: "/tmp/run-sanitized",
               source_contract: source_contract,
               inherited_env: %{}
             )

    evidence = ChildLaunchPolicy.sanitize(envelope)
    refute inspect(evidence) =~ @secret
    assert evidence["requested_action_summary"] == %{"allow" => 1}
  end

  test "resolve is total and returns sanitized blocked evidence for malformed inputs" do
    valid = [adapter: "pi", run_dir: "/tmp/run-total", inherited_env: %{}]

    examples = [
      {[], :invalid_adapter},
      {[run_dir: "/tmp/run-total"], :invalid_adapter},
      {[adapter: "pi"], :invalid_run_dir},
      {[:malformed], :invalid_options},
      {%{adapter: "pi"}, :invalid_options},
      {Keyword.put(valid, :unsafe_bypass, "yes"), :invalid_unsafe_bypass},
      {Keyword.put(valid, :inherited_env, [{"PATH", "/bin"}]), :invalid_inherited_environment},
      {Keyword.put(valid, :source_contract, "manifest"), :invalid_source_contract},
      {Keyword.put(valid, :provider_auth_env_names, %{}), :invalid_provider_auth_profile}
    ]

    for {input, reason} <- examples do
      assert {:block, envelope} = ChildLaunchPolicy.resolve(input)
      assert envelope.reason == reason
      assert envelope.environment == %{}
      evidence = ChildLaunchPolicy.sanitize(envelope)
      assert evidence["decision"] == "block"
      refute inspect(evidence) =~ @secret
    end

    assert {:block, malformed_bypass} =
             ChildLaunchPolicy.resolve(Keyword.put(valid, :unsafe_bypass, "yes"))

    evidence = ChildLaunchPolicy.sanitize(malformed_bypass)
    assert evidence["bypass"]["requested"] == false
    assert evidence["bypass"]["attempted"] == true
  end
end
