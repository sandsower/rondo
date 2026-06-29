defmodule Rondo.EscalationTest do
  use Rondo.TestSupport

  alias Rondo.Escalation

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), escalation_enabled: true)
    :ok
  end

  defp manifest(overrides) do
    defaults = %{
      "run_id" => "run-1",
      "status" => "failed",
      "failure_classification" => "task_failure",
      "final_report" => %{"status" => "missing", "errors" => []},
      "agent" => %{
        "model_routing" => %{"requested_tier" => "light"},
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3}
      },
      "timestamps" => %{"started_at" => "2026-06-29T00:00:00Z", "finished_at" => "2026-06-29T00:01:00Z"}
    }

    Map.merge(defaults, normalize(overrides))
  end

  defp normalize(nil), do: nil
  defp normalize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_binary(value), do: value
  defp normalize(value) when is_integer(value), do: value
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {normalize(key), normalize(val)} end)
    |> Map.new()
  end

  defp make_entry(run_id, tier, reason, status, total_tokens) do
    %{
      run_id: run_id,
      tier: tier,
      reason: reason,
      status: status,
      failure_classification: nil,
      gate_summary: nil,
      final_report_status: nil,
      token_spend: %{input_tokens: 0, output_tokens: 0, total_tokens: total_tokens},
      started_at: "2026-06-29T00:00:00Z",
      finished_at: "2026-06-29T00:01:00Z",
      run_dir: nil
    }
  end

  describe "config" do
    test "returns repo defaults when no source contract override exists" do
      write_workflow_file!(Workflow.workflow_file_path(),
        escalation_enabled: true,
        escalation_max_total_attempts: 5
      )

      WorkflowStore.force_reload()
      config = Escalation.resolve_config(%{})

      assert config.enabled == true
      assert config.tiers == ["light", "standard", "heavy", "frontier"]
      assert config.max_total_attempts == 5
      assert config.report_repair_attempts == 2
      assert config.token_budget == nil
    end

    test "source contract override wins over repo config" do
      override = %{
        "escalation" => %{
          "enabled" => true,
          "tiers" => ["light", "standard"],
          "max_total_attempts" => 2,
          "token_budget" => 1_000_000,
          "report_repair_attempts" => 1
        }
      }

      config = Escalation.resolve_config(override)
      assert config.enabled == true
      assert config.tiers == ["light", "standard"]
      assert config.max_total_attempts == 2
      assert config.token_budget == 1_000_000
      assert config.report_repair_attempts == 1
    end
  end

  describe "pass-on-first" do
    test "a completed run with valid final report is done" do
      m =
        manifest(%{
          status: "completed",
          final_report: %{"status" => "valid", "path" => "artifacts/final-report.json"},
          failure_classification: nil
        })

      assert {:done, chain} = Escalation.after_attempt(m, [])
      assert length(chain) == 1
      assert List.last(chain).status == :completed
    end
  end

  describe "escalation" do
    test "gates/code failure escalates to next tier" do
      m =
        manifest(%{
          status: "failed",
          failure_classification: "task_failure",
          final_report: %{"status" => "missing", "errors" => []},
          latest_gate: %{"status" => "fail", "failed" => [%{"name" => "elixir-ci"}]}
        })

      assert {:escalate, tier, chain, prompt} = Escalation.after_attempt(m, [])
      assert tier == "standard"
      assert [_] = chain
      assert List.last(chain).tier == "light"
      assert is_binary(prompt) and String.contains?(prompt, "escalated attempt at tier `standard`")
    end

    test "escalates once per failure and then passes after success" do
      fail_manifest = fn tier, index ->
        manifest(%{
          run_id: "run-#{index}",
          status: "failed",
          failure_classification: "task_failure",
          final_report: %{"status" => "missing", "errors" => []},
          agent: %{
            "model_routing" => %{"requested_tier" => tier},
            "usage" => %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 10}
          },
          latest_gate: %{"status" => "fail", "failed" => [%{"name" => "elixir-ci"}]}
        })
      end

      {:escalate, "standard", chain, _} = Escalation.after_attempt(fail_manifest.("light", 1), [])
      assert length(chain) == 1

      success =
        manifest(%{
          run_id: "run-2",
          status: "completed",
          final_report: %{"status" => "valid", "path" => "final-report.json"},
          failure_classification: nil,
          agent: %{
            "model_routing" => %{"requested_tier" => "standard"},
            "usage" => %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 10}
          }
        })

      assert {:done, chain} = Escalation.after_attempt(success, chain)
      assert length(chain) == 2
      assert List.last(chain).tier == "standard"
    end
  end

  describe "ladder exhausted" do
    test "frontier failure with no higher tier pauses" do
      m =
        manifest(%{
          status: "failed",
          failure_classification: "task_failure",
          agent: %{
            "model_routing" => %{"requested_tier" => "frontier"},
            "usage" => %{"total_tokens" => 1}
          }
        })

      assert {:pause, "ladder_exhausted", chain} = Escalation.after_attempt(m, [])
      assert length(chain) == 1
    end
  end

  describe "max_total_attempts ceiling" do
    test "pauses when the chain already contains max_total_attempts attempts" do
      chain = [
        make_entry("run-1", "light", :initial, :failed, 1),
        make_entry("run-2", "standard", :escalation, :failed, 1),
        make_entry("run-3", "heavy", :escalation, :failed, 1)
      ]

      heavy =
        manifest(%{
          run_id: "run-4",
          status: "failed",
          failure_classification: "task_failure",
          agent: %{
            "model_routing" => %{"requested_tier" => "heavy"},
            "usage" => %{"total_tokens" => 1}
          }
        })

      override = %{
        "escalation" => %{
          "enabled" => true,
          "tiers" => ["light", "standard", "heavy", "frontier"],
          "max_total_attempts" => 4,
          "report_repair_attempts" => 2
        }
      }

      assert {:pause, "max_total_attempts_exceeded", chain_out} = Escalation.after_attempt(heavy, chain, override)
      assert length(chain_out) == 4
    end
  end

  describe "token budget ceiling" do
    test "pauses when the accumulated token spend reaches the budget" do
      chain = [
        make_entry("run-1", "light", :initial, :failed, 500),
        make_entry("run-2", "standard", :escalation, :failed, 500)
      ]

      standard =
        manifest(%{
          run_id: "run-3",
          status: "failed",
          failure_classification: "task_failure",
          agent: %{
            "model_routing" => %{"requested_tier" => "standard"},
            "usage" => %{"total_tokens" => 1}
          }
        })

      override = %{
        "escalation" => %{
          "enabled" => true,
          "tiers" => ["light", "standard", "heavy"],
          "max_total_attempts" => 10,
          "token_budget" => 1_000,
          "report_repair_attempts" => 2
        }
      }

      assert {:pause, "token_budget_exceeded", chain_out} = Escalation.after_attempt(standard, chain, override)
      assert length(chain_out) == 3
    end
  end

  describe "report repair" do
    test "missing final report triggers same-tier repair" do
      m =
        manifest(%{
          status: "completed",
          failure_classification: "final_report_missing",
          final_report: %{"status" => "missing", "errors" => ["final report missing or not parseable"]}
        })

      assert {:repair, chain, prompt} = Escalation.after_attempt(m, [])
      assert List.last(chain).tier == "light"
      assert is_binary(prompt) and String.contains?(prompt, "same-tier repair attempt")
    end

    test "invalid final report triggers same-tier repair" do
      m =
        manifest(%{
          status: "completed",
          failure_classification: "final_report_invalid",
          final_report: %{"status" => "invalid", "errors" => ["summary must be a non-empty string"]}
        })

      assert {:repair, _chain, _prompt} = Escalation.after_attempt(m, [])
    end

    test "repair success transitions to done" do
      bad =
        manifest(%{
          run_id: "run-1",
          status: "completed",
          failure_classification: "final_report_invalid",
          final_report: %{"status" => "invalid", "errors" => []}
        })

      assert {:repair, chain, _prompt} = Escalation.after_attempt(bad, [])

      good =
        manifest(%{
          run_id: "run-2",
          status: "completed",
          failure_classification: nil,
          final_report: %{"status" => "valid", "path" => "final-report.json"}
        })

      assert {:done, chain} = Escalation.after_attempt(good, chain)
      assert length(chain) == 2
    end

    test "repair exhausts after configured attempts and pauses" do
      bad =
        manifest(%{
          run_id: "run-1",
          status: "completed",
          failure_classification: "final_report_missing",
          final_report: %{"status" => "missing", "errors" => []}
        })

      assert {:repair, chain_one, _} = Escalation.after_attempt(bad, [])

      override = %{
        "escalation" => %{
          "enabled" => true,
          "tiers" => ["light", "standard", "heavy"],
          "max_total_attempts" => 10,
          "report_repair_attempts" => 1
        }
      }

      next_bad =
        manifest(%{
          run_id: "run-2",
          status: "completed",
          failure_classification: "final_report_missing",
          final_report: %{"status" => "missing", "errors" => []},
          escalation: %{"current_attempt" => %{"reason" => "report_repair"}}
        })

      assert {:pause, "report_repair_exhausted", chain} = Escalation.after_attempt(next_bad, chain_one, override)
      assert length(chain) == 2
    end
  end

  describe "disabled escalation" do
    test "failed run pauses because escalation is disabled" do
      m =
        manifest(%{
          status: "failed",
          failure_classification: "task_failure"
        })

      assert {:pause, "escalation_disabled", _chain} =
               Escalation.after_attempt(m, [], %{
                 "escalation" => %{"enabled" => false}
               })
    end
  end

  describe "policy widening prevention" do
    test "escalation prompt reminds the agent not to widen the action policy" do
      m =
        manifest(%{
          status: "failed",
          failure_classification: "task_failure"
        })

      assert {:escalate, "standard", _chain, prompt} = Escalation.after_attempt(m, [])
      assert String.contains?(prompt, "do not widen allowed/ask/deny")
    end
  end
end
