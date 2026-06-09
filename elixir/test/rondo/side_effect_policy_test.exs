defmodule Rondo.SideEffectPolicyTest do
  use Rondo.TestSupport, async: true

  alias Rondo.SideEffectPolicy

  @sandbox %{baseline: "separate-worktree", default_branch: false, uncommitted_changes: false}

  test "default evaluator and guidance interrupt defaults are callable" do
    assert {status, decision} = SideEffectPolicy.evaluate(%{action: "file.read", classes: ["read"]})
    assert status in [:ok, :blocked]
    assert is_map(decision.envelope)

    interrupt = SideEffectPolicy.guidance_interrupt(tracker_transition_side_effect(), %{"decision" => "ask"})
    assert interrupt["reason"] == "action_policy_guidance_required"
  end

  test "allows allowed side effects and returns the evaluator envelope" do
    side_effect = tracker_transition_side_effect()

    assert {:ok, decision} =
             SideEffectPolicy.evaluate(side_effect,
               evaluator: evaluator("allow"),
               sandbox_status: @sandbox
             )

    assert decision.side_effect_status == :allowed
    assert decision.envelope["decision"] == "allow"
    assert decision.interrupt == nil
  end

  test "turns ask decisions into Needs Guidance interrupts with deterministic suggestions" do
    side_effect = tracker_transition_side_effect()

    assert {:blocked, decision} =
             SideEffectPolicy.evaluate(side_effect,
               evaluator: evaluator("ask"),
               sandbox_status: @sandbox,
               now: ~U[2026-05-28 10:11:12Z],
               resume: %{run_id: "run-1"}
             )

    assert decision.side_effect_status == :blocked
    assert decision.block_reason == :action_policy_requires_guidance
    assert decision.envelope["decision"] == "ask"

    interrupt = decision.interrupt
    assert interrupt["reason"] == "action_policy_guidance_required"
    assert interrupt["guidance_severity"] == "warning"
    assert interrupt["blocked_side_effect"]["action"] == "tracker.issue.transition"
    assert interrupt["blocked_side_effect"]["resume_safe"] == true
    assert interrupt["blocked_side_effect"]["skip_behavior"] == "block"
    assert interrupt["policy"]["decision"] == "ask"
    assert interrupt["resume"] == %{"run_id" => "run-1", "side_effect_id" => "tracker-transition:issue-58:in-progress"}

    assert [approve_once, abort_run] = interrupt["suggested_responses"]
    assert approve_once["id"] == "approve_once"
    assert approve_once["quick"] == true
    assert approve_once["deterministic"] == true
    assert abort_run["id"] == "abort_run"
  end

  test "does not expose approve_once or unsupported skip responses for non-resume-safe side effects" do
    side_effect = %{
      action: "workspace.hook.before_run",
      classes: ["workspace-write"],
      label: "Before-run hook",
      operation: "Run configured before_run workspace hook",
      required: false,
      resume_safe: false,
      skip_behavior: "continue",
      side_effect_id: "workspace-hook:before-run"
    }

    assert {:blocked, decision} =
             SideEffectPolicy.evaluate(side_effect,
               evaluator: evaluator("ask"),
               sandbox_status: @sandbox
             )

    responses = decision.interrupt["suggested_responses"]
    refute Enum.any?(responses, &(&1["id"] == "approve_once"))
    refute Enum.any?(responses, &(&1["id"] == "skip_side_effect"))
    assert Enum.any?(responses, &(&1["id"] == "abort_run"))
  end

  test "derives critical/info severity and validates skip behavior fallbacks" do
    destructive = %{
      action: "workspace.cleanup.remove_tmp",
      classes: ["workspace-destructive"],
      required: false,
      resume_safe: false,
      skip_behavior: "not-valid"
    }

    assert {:blocked, destructive_decision} =
             SideEffectPolicy.evaluate(destructive,
               evaluator: evaluator("ask"),
               sandbox_status: @sandbox
             )

    assert destructive_decision.interrupt["guidance_severity"] == "critical"
    assert destructive_decision.interrupt["blocked_side_effect"]["label"] == "workspace.cleanup.remove_tmp"
    assert destructive_decision.interrupt["blocked_side_effect"]["skip_behavior"] == "block"
    assert destructive_decision.interrupt["resume"] == %{"side_effect_id" => "workspace.cleanup.remove_tmp"}
    refute Map.has_key?(destructive_decision.interrupt["upcoming_transitions"], "skip_side_effect")

    optional = %{
      action: "workspace.hook.after_run",
      classes: [],
      required: false,
      resume_safe: false,
      skip_behavior: "continue"
    }

    assert SideEffectPolicy.guidance_severity(optional, %{"decision" => "ask"}) == "info"
  end

  test "keeps the original ledger when recording a policy decision fails" do
    workspace_root = tmp_dir("side-effect-policy-ledger-failure")
    issue = %Issue{id: "issue-ledger-fail", identifier: "GH-POLICY-FAIL", title: "Policy", state: "Todo"}

    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root)
    File.rm!(ledger.manifest_path)
    File.mkdir_p!(ledger.manifest_path)

    assert {:ok, decision} =
             SideEffectPolicy.evaluate(tracker_transition_side_effect(),
               evaluator: evaluator("allow"),
               sandbox_status: @sandbox,
               ledger: ledger
             )

    assert decision.ledger == ledger
    File.rm_rf!(workspace_root)
  end

  test "records policy decisions into a run ledger when available" do
    workspace_root = tmp_dir("side-effect-policy-ledger")
    issue = %Issue{id: "issue-ledger", identifier: "GH-POLICY", title: "Policy", state: "Todo"}

    assert {:ok, ledger} = Rondo.RunLedger.create_run(issue, workspace_root: workspace_root)

    assert {:ok, decision} =
             SideEffectPolicy.evaluate(tracker_transition_side_effect(),
               evaluator: evaluator("allow"),
               sandbox_status: @sandbox,
               ledger: ledger
             )

    assert %Rondo.RunLedger{} = decision.ledger
    manifest = decision.ledger.manifest_path |> File.read!() |> Jason.decode!()
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "action_policy_decision"))

    File.rm_rf!(workspace_root)
  end

  test "invalid evaluator envelopes fail closed" do
    assert {:blocked, failed} =
             SideEffectPolicy.evaluate(tracker_transition_side_effect(),
               evaluator: fn _action, _classes, _opts -> {:ok, %{"decision" => "maybe"}} end,
               sandbox_status: @sandbox
             )

    assert failed.block_reason == {:action_policy_failed, :invalid_evaluator_envelope}
    assert failed.envelope == %{"decision" => "maybe"}
    assert failed.interrupt == nil
  end

  test "deny decisions and evaluator failures fail closed without running side effects" do
    side_effect = tracker_transition_side_effect()

    assert {:blocked, denied} =
             SideEffectPolicy.evaluate(side_effect,
               evaluator: evaluator("deny"),
               sandbox_status: @sandbox
             )

    assert denied.block_reason == :action_policy_denied
    assert denied.envelope["decision"] == "deny"

    assert {:blocked, failed} =
             SideEffectPolicy.evaluate(side_effect,
               evaluator: fn _action, _classes, _opts -> {:error, :boom} end,
               sandbox_status: @sandbox
             )

    assert failed.block_reason == {:action_policy_failed, :boom}
    assert failed.envelope == nil
  end

  defp tracker_transition_side_effect do
    %{
      action: "tracker.issue.transition",
      classes: ["tracker-write"],
      label: "Tracker update",
      operation: "Change issue GH-58 from Todo to In Progress",
      required: true,
      resume_safe: true,
      skip_behavior: "block",
      side_effect_id: "tracker-transition:issue-58:in-progress"
    }
  end

  defp tmp_dir(name), do: Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")

  defp evaluator(decision) do
    fn action, classes, _opts ->
      {:ok,
       %{
         "decision" => decision,
         "action" => action,
         "classes" => classes,
         "mode" => "supervised-auto",
         "log_level" => if(decision == "deny", do: "error", else: "warning"),
         "requires_human" => decision == "ask",
         "reason" => "test #{decision}",
         "matched_rules" => [%{"class" => List.first(classes), "decision" => decision}],
         "remediation" => []
       }}
    end
  end
end
