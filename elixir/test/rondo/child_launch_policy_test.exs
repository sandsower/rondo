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
    assert envelope.bypass == %{requested: true, applied: true, reason: :explicit_supervised_run_once}
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
               isolation_baseline: :os_credential_isolated,
               run_dir: "/tmp/run-sanitized",
               source_contract: source_contract,
               inherited_env: %{}
             )

    evidence = ChildLaunchPolicy.sanitize(envelope)
    refute inspect(evidence) =~ @secret
    assert evidence["requested_action_summary"] == %{"allow" => 1}
  end
end
