defmodule Rondo.TelemetryTest do
  use ExUnit.Case, async: true

  alias Rondo.Telemetry

  setup do
    test_pid = self()
    handler_id = "telemetry-test-#{inspect(test_pid)}-#{System.unique_integer([:positive, :monotonic])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:rondo, :run, :start],
        [:rondo, :run, :stop],
        [:rondo, :gate, :stop],
        [:rondo, :clean_eval, :stop],
        [:rondo, :final_report, :recorded],
        [:rondo, :escalation, :decision]
      ],
      fn event, measurements, metadata, _config -> send(test_pid, {:telemetry, event, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "run_start/2 emits with run_id merged into metadata" do
    Telemetry.run_start("run-1", %{adapter: "claude_code"})
    assert_receive {:telemetry, [:rondo, :run, :start], %{}, %{run_id: "run-1", adapter: "claude_code"}}
  end

  test "run_start/1 defaults metadata to an empty map" do
    Telemetry.run_start("run-1")
    assert_receive {:telemetry, [:rondo, :run, :start], %{}, %{run_id: "run-1"}}
  end

  test "run_stop/4 emits duration and string status, accepting atom or string status" do
    Telemetry.run_stop("run-1", 1234, :completed, %{adapter: "claude_code"})
    assert_receive {:telemetry, [:rondo, :run, :stop], %{duration: 1234}, %{run_id: "run-1", status: "completed", adapter: "claude_code"}}

    Telemetry.run_stop("run-2", nil, "failed")
    assert_receive {:telemetry, [:rondo, :run, :stop], %{duration: nil}, %{run_id: "run-2", status: "failed"}}
  end

  test "gate_stop/4 emits gate name, status, and duration" do
    Telemetry.gate_stop("run-1", "unit", :pass, 42)
    assert_receive {:telemetry, [:rondo, :gate, :stop], %{duration: 42}, %{run_id: "run-1", gate: "unit", status: "pass"}}
  end

  test "clean_eval_stop/2 emits run_id and status" do
    Telemetry.clean_eval_stop("run-1", :fail)
    assert_receive {:telemetry, [:rondo, :clean_eval, :stop], %{}, %{run_id: "run-1", status: "fail"}}
  end

  test "final_report_recorded/2 emits run_id and status" do
    Telemetry.final_report_recorded("run-1", "invalid")
    assert_receive {:telemetry, [:rondo, :final_report, :recorded], %{}, %{run_id: "run-1", status: "invalid"}}
  end

  test "escalation_decision/2 derives metadata for :done" do
    Telemetry.escalation_decision("run-1", {:done, []})
    assert_receive {:telemetry, [:rondo, :escalation, :decision], %{}, %{run_id: "run-1", decision: :done}}
  end

  test "escalation_decision/2 derives metadata for :pause with reason" do
    Telemetry.escalation_decision("run-1", {:pause, "max_total_attempts_exceeded", []})
    assert_receive {:telemetry, [:rondo, :escalation, :decision], %{}, %{run_id: "run-1", decision: :pause, reason: "max_total_attempts_exceeded"}}
  end

  test "escalation_decision/2 derives metadata for :escalate with next_tier" do
    Telemetry.escalation_decision("run-1", {:escalate, "standard", [], "prompt"})
    assert_receive {:telemetry, [:rondo, :escalation, :decision], %{}, metadata}
    assert metadata == %{run_id: "run-1", decision: :escalate, next_tier: "standard"}
  end

  test "escalation_decision/2 derives metadata for :repair" do
    Telemetry.escalation_decision("run-1", {:repair, [], "prompt"})
    assert_receive {:telemetry, [:rondo, :escalation, :decision], %{}, %{run_id: "run-1", decision: :repair}}
  end
end
