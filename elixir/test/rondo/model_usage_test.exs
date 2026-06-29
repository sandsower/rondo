defmodule Rondo.ModelUsageTest do
  use ExUnit.Case

  alias Rondo.ModelUsage

  describe "provider_from_model/1" do
    test "extracts codex provider" do
      assert ModelUsage.provider_from_model("openai-codex/gpt-5.4-mini") == "codex"
      assert ModelUsage.provider_from_model("openai-codex/gpt-5.5") == "codex"
    end

    test "extracts openrouter provider" do
      assert ModelUsage.provider_from_model("openrouter/moonshotai/kimi-k2.7-code") == "openrouter"
      assert ModelUsage.provider_from_model("openrouter/anthropic/claude-sonnet-4-20250514") == "openrouter"
    end

    test "extracts openai provider" do
      assert ModelUsage.provider_from_model("openai/gpt-4o") == "openai"
    end

    test "extracts anthropic provider" do
      assert ModelUsage.provider_from_model("anthropic/claude-sonnet-4-20250514") == "anthropic"
    end

    test "fuzzy matches codex and openrouter in model strings" do
      assert ModelUsage.provider_from_model("some-codex-model") == "codex"
      assert ModelUsage.provider_from_model("openrouter-variant") == "openrouter"
    end

    test "returns nil for unrecognized models" do
      assert ModelUsage.provider_from_model("gemini-2.5-flash") == nil
      assert ModelUsage.provider_from_model(nil) == nil
    end
  end

  describe "model_key/2" do
    test "uses model when available" do
      assert ModelUsage.model_key("pi", "openai-codex/gpt-5.4-mini") == "openai-codex/gpt-5.4-mini"
    end

    test "falls back to adapter when model is nil" do
      assert ModelUsage.model_key("pi", nil) == "adapter:pi"
    end

    test "returns nil when both are nil" do
      assert ModelUsage.model_key(nil, nil) == nil
    end
  end

  describe "aggregate/2" do
    test "returns empty aggregates for empty inputs" do
      result = ModelUsage.aggregate([], [])
      assert result.total_runs == 0
      assert result.total_tokens == 0
      assert result.codex_pct == 0.0
      assert result.openrouter_pct == 0.0
      assert result.by_provider == %{}
      assert result.by_model == %{}
    end

    test "aggregates a single codex run" do
      running = [codex_run("RON-10", "openai-codex/gpt-5.4-mini", 1500)]
      result = ModelUsage.aggregate(running, [])

      assert result.total_runs == 1
      assert result.total_tokens == 1500
      assert result.codex_pct == 100.0
      assert result.openrouter_pct == 0.0
      assert Map.has_key?(result.by_provider, "codex")
      assert result.by_provider["codex"].run_count == 1
    end

    test "aggregates a single openrouter run" do
      running = [openrouter_run("RON-29", "openrouter/moonshotai/kimi-k2.7-code", 2000)]
      result = ModelUsage.aggregate(running, [])

      assert result.total_runs == 1
      assert result.codex_pct == 0.0
      assert result.openrouter_pct == 100.0
      assert Map.has_key?(result.by_provider, "openrouter")
    end

    test "aggregates mixed provider runs" do
      running = [
        codex_run("RON-10", "openai-codex/gpt-5.4-mini", 1000),
        openrouter_run("RON-29", "openrouter/moonshotai/kimi-k2.7-code", 2000),
        codex_run("RON-48", "openai-codex/gpt-5.4-mini", 500)
      ]

      archived = [
        codex_run("RON-30", "openai-codex/gpt-5.5", 3000)
      ]

      result = ModelUsage.aggregate(running, archived)

      assert result.total_runs == 4
      assert result.total_tokens == 6500
      assert result.codex_pct == 75.0
      assert result.openrouter_pct == 25.0
      assert result.by_provider["codex"].run_count == 3
      assert result.by_provider["openrouter"].run_count == 1
    end

    test "computes per-model breakdown" do
      runs = [
        codex_run("A", "openai-codex/gpt-5.4-mini", 100),
        codex_run("B", "openai-codex/gpt-5.4-mini", 200),
        codex_run("C", "openai-codex/gpt-5.5", 300)
      ]

      result = ModelUsage.aggregate(runs, [])

      assert Map.has_key?(result.by_model, "openai-codex/gpt-5.4-mini")
      assert Map.has_key?(result.by_model, "openai-codex/gpt-5.5")
      assert result.by_model["openai-codex/gpt-5.4-mini"].run_count == 2
      assert result.by_model["openai-codex/gpt-5.5"].run_count == 1
      assert result.by_model["openai-codex/gpt-5.5"].provider == "codex"
    end

    test "computes token percentages across providers" do
      runs = [
        codex_run("A", "openai-codex/gpt-5.4-mini", 500),
        openrouter_run("B", "openrouter/kimi", 500)
      ]

      result = ModelUsage.aggregate(runs, [])

      assert result.by_provider["codex"].token_pct == 50.0
      assert result.by_provider["openrouter"].token_pct == 50.0
    end

    test "handles runs without explicit model_routing by adapter fallback" do
      runs = [
        %{
          "identifier" => "TEST-1",
          "adapter" => "pi",
          "started_at" => ~U[2026-06-29 10:00:00Z],
          "tokens" => %{"total_tokens" => 100}
        }
      ]

      result = ModelUsage.aggregate(runs, [])

      assert result.total_runs == 1
      assert result.total_tokens == 100
      assert result.by_model["adapter:pi"].run_count == 1
      assert result.by_model["adapter:pi"].provider == nil
    end

    test "keeps aggregate model map unchanged when routing has no model or adapter" do
      runs = [
        %{
          "identifier" => "TEST-NO-MODEL",
          "model_routing" => %{"resolved" => "manual"},
          "started_at" => ~U[2026-06-29 10:00:00Z],
          "tokens" => %{"total_tokens" => 100}
        }
      ]

      result = ModelUsage.aggregate(runs, [])

      assert result.total_runs == 1
      assert result.total_tokens == 100
      assert result.by_provider == %{}
      assert result.by_model == %{}
    end

    test "model_routing stored info takes precedence over top-level adapter field" do
      runs = [
        %{
          "identifier" => "TEST-2",
          "adapter" => "claude_code",
          "model_routing" => %{
            "status" => "honored",
            "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"}
          },
          "started_at" => ~U[2026-06-29 10:00:00Z],
          "tokens" => %{"total_tokens" => 200}
        }
      ]

      result = ModelUsage.aggregate(runs, [])

      assert Map.has_key?(result.by_model, "openai-codex/gpt-5.4-mini")
      refute Map.has_key?(result.by_model, "adapter:claude_code")
      assert result.codex_pct == 100.0
    end

    test "handles claude_total_tokens format" do
      runs = [
        %{
          "identifier" => "TEST-3",
          "model_routing" => %{
            "resolved" => %{"model" => "openai-codex/gpt-5.4-mini"}
          },
          "claude_total_tokens" => 350,
          "started_at" => ~U[2026-06-29 10:00:00Z]
        }
      ]

      result = ModelUsage.aggregate(runs, [])
      assert result.total_tokens == 350
    end
  end

  describe "active_codex_consumers/1" do
    test "returns empty list when no codex runs" do
      runs = [openrouter_run("RON-29", "openrouter/kimi", 100)]
      assert ModelUsage.active_codex_consumers(runs) == []
    end

    test "detects active codex consumers" do
      runs = [
        codex_run("RON-10", "openai-codex/gpt-5.4-mini", 1000),
        openrouter_run("RON-29", "openrouter/kimi", 2000),
        codex_run("RON-48", "openai-codex/gpt-5.5", 500)
      ]

      consumers = ModelUsage.active_codex_consumers(runs)

      assert length(consumers) == 2
      assert Enum.map(consumers, & &1.identifier) |> Enum.sort() == ["RON-10", "RON-48"]
      assert Enum.find(consumers, &(&1.identifier == "RON-10")).model == "openai-codex/gpt-5.4-mini"
      assert Enum.find(consumers, &(&1.identifier == "RON-10")).provider == "codex"
    end

    test "detects codex by model string content" do
      runs = [
        %{
          "identifier" => "MEM-74",
          "model_routing" => %{
            "resolved" => %{"model" => "openai-codex/gpt-5.5"}
          },
          "tokens" => %{"total_tokens" => 800}
        }
      ]

      consumers = ModelUsage.active_codex_consumers(runs)
      assert length(consumers) == 1
      assert hd(consumers).identifier == "MEM-74"
    end

    test "sorts results by identifier" do
      runs = [
        codex_run("RON-48", "openai-codex/gpt-5.5", 100),
        codex_run("RON-10", "openai-codex/gpt-5.4-mini", 100),
        codex_run("BEI-49", "openai-codex/gpt-5.4-mini", 100)
      ]

      consumers = ModelUsage.active_codex_consumers(runs)
      assert Enum.map(consumers, & &1.identifier) == ["BEI-49", "RON-10", "RON-48"]
    end
  end

  describe "model_timeline/1" do
    test "returns empty timeline for empty input" do
      assert ModelUsage.model_timeline([]) == []
    end

    test "builds timeline for a single run" do
      runs = [
        %{
          "identifier" => "RON-10",
          "started_at" => ~U[2026-06-29 10:00:00Z],
          "model_routing" => %{
            "status" => "honored",
            "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"},
            "reason" => "resolved tier standard to openai-codex/gpt-5.4-mini"
          }
        }
      ]

      timeline = ModelUsage.model_timeline(runs)

      assert length(timeline) == 1
      entry = hd(timeline)
      assert entry.model == "openai-codex/gpt-5.4-mini"
      assert entry.provider == "codex"
      assert entry.adapter == "pi"
      assert entry.boundary == "initial_spawn"
    end

    test "builds timeline with retry and switch boundaries" do
      runs = [
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 09:00:00Z],
          "model_routing" => %{
            "resolved" => %{"model" => "openai-codex/gpt-5.4-mini"}
          },
          "exit_reason" => "exited: some error"
        },
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 10:00:00Z],
          "retry_attempt" => 1,
          "model_routing" => %{
            "resolved" => %{"model" => "openrouter/moonshotai/kimi-k2.7-code"}
          }
        }
      ]

      timeline = ModelUsage.model_timeline(runs)

      assert length(timeline) == 2
      first = Enum.at(timeline, 0)
      second = Enum.at(timeline, 1)

      assert first.model == "openai-codex/gpt-5.4-mini"
      assert first.boundary in ["retry", "terminated"]

      assert second.model == "openrouter/moonshotai/kimi-k2.7-code"
      assert second.boundary == "retry"
    end

    test "chronological ordering" do
      runs = [
        %{
          "identifier" => "RON-30",
          "started_at" => ~U[2026-06-29 11:00:00Z],
          "model_routing" => %{"resolved" => %{"model" => "openrouter/kimi"}}
        },
        %{
          "identifier" => "RON-30",
          "started_at" => ~U[2026-06-29 09:00:00Z],
          "model_routing" => %{"resolved" => %{"model" => "openai-codex/gpt-5.4-mini"}}
        }
      ]

      timeline = ModelUsage.model_timeline(runs)

      assert length(timeline) == 2
      # First entry should be earliest
      assert hd(timeline).model == "openai-codex/gpt-5.4-mini"
      # Last entry should be latest
      assert List.last(timeline).model == "openrouter/kimi"
    end

    test "handles runs with no model_routing" do
      runs = [
        %{
          "identifier" => "RON-50",
          "started_at" => ~U[2026-06-29 10:00:00Z]
        }
      ]

      timeline = ModelUsage.model_timeline(runs)

      assert length(timeline) == 1
      entry = hd(timeline)
      assert entry.model == nil
      assert entry.boundary == "initial_spawn"
    end

    test "handles resolved routing strings, terminal exits, and missing timestamps" do
      runs = [
        %{
          "identifier" => "RON-10",
          "started_at" => "2026-06-29T10:00:00Z",
          "model_routing" => %{
            "resolved" => %{"model" => "openrouter/moonshotai/kimi-k2.7-code"}
          },
          "exit_reason" => "completed"
        },
        %{
          "identifier" => "RON-11",
          "model_routing" => %{
            "resolved" => "manual"
          }
        },
        %{
          "identifier" => "RON-12",
          "started_at" => ~U[2026-06-29 11:00:00Z],
          "model_routing" => %{
            "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.5"}
          },
          "exit_reason" => "terminated"
        }
      ]

      timeline = ModelUsage.model_timeline(runs)

      assert Enum.any?(timeline, &(&1.model == "openrouter/moonshotai/kimi-k2.7-code" and &1.boundary == "completed" and &1.at == "2026-06-29T10:00:00Z"))
      assert Enum.any?(timeline, &(&1.model == nil and &1.boundary == "active" and is_nil(&1.at)))
      assert Enum.any?(timeline, &(&1.model == "openai-codex/gpt-5.5" and &1.boundary == "terminated" and &1.at == "2026-06-29T11:00:00Z"))
    end
  end

  describe "model_roles/1" do
    test "returns nil active for empty input" do
      roles = ModelUsage.model_roles([])
      assert roles.active == nil
      assert roles.historical == []
      assert roles.fallback == []
    end

    test "distinguishes active from historical models" do
      runs = [
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 09:00:00Z],
          "model_routing" => %{
            "resolved" => %{"model" => "openai-codex/gpt-5.4-mini"}
          }
        },
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 10:00:00Z],
          "model_routing" => %{
            "resolved" => %{"model" => "openrouter/moonshotai/kimi-k2.7-code"},
            "status" => "honored"
          }
        }
      ]

      roles = ModelUsage.model_roles(runs)

      assert roles.active.model == "openrouter/moonshotai/kimi-k2.7-code"
      assert roles.active.provider == "openrouter"
      assert length(roles.historical) == 1
      assert hd(roles.historical).model == "openai-codex/gpt-5.4-mini"
      assert hd(roles.historical).provider == "codex"
    end

    test "identifies fallback candidates" do
      runs = [
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 10:00:00Z],
          "model_routing" => %{
            "status" => "honored",
            "resolved" => %{"model" => "openrouter/kimi"},
            "candidates" => [
              %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"},
              %{"adapter" => "pi", "model" => "openrouter/kimi"},
              %{"adapter" => "pi", "model" => "openrouter/other-model"}
            ]
          }
        }
      ]

      roles = ModelUsage.model_roles(runs)

      assert roles.active.model == "openrouter/kimi"
      fallback_models = Enum.map(roles.fallback, & &1.model)

      # The resolved model should not appear in fallback candidates
      refute "openrouter/kimi" in fallback_models
      assert "openai-codex/gpt-5.4-mini" in fallback_models
      assert "openrouter/other-model" in fallback_models
    end

    test "deduplicates historical models" do
      runs = [
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 08:00:00Z],
          "model_routing" => %{"resolved" => %{"model" => "openai-codex/gpt-5.4-mini"}}
        },
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 09:00:00Z],
          "model_routing" => %{"resolved" => %{"model" => "openai-codex/gpt-5.4-mini"}}
        },
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 10:00:00Z],
          "model_routing" => %{"resolved" => %{"model" => "openrouter/kimi"}}
        }
      ]

      roles = ModelUsage.model_roles(runs)

      assert roles.active.model == "openrouter/kimi"
      # Two historical attempts used the same model, so only one unique entry
      assert length(roles.historical) == 1
      assert hd(roles.historical).model == "openai-codex/gpt-5.4-mini"
    end

    test "handles runs without model_routing gracefully" do
      runs = [
        %{
          "identifier" => "RON-50",
          "started_at" => ~U[2026-06-29 10:00:00Z]
        }
      ]

      roles = ModelUsage.model_roles(runs)

      assert roles.active != nil
      assert roles.active.model == nil
      assert roles.historical == []
      assert roles.fallback == []
    end

    test "sorts invalid and missing started_at values safely" do
      runs = [
        %{
          "identifier" => "GOOD",
          "started_at" => ~U[2026-06-29 12:00:00Z],
          "model_routing" => %{"resolved" => %{"model" => "openrouter/kimi"}}
        },
        %{
          "identifier" => "STRING",
          "started_at" => "2026-06-29T11:30:00Z",
          "model_routing" => %{"resolved" => %{"model" => "openrouter/kimi-2"}}
        },
        %{
          "identifier" => "BAD",
          "started_at" => "not-a-date",
          "model_routing" => %{"resolved" => %{"model" => "openai-codex/gpt-5.4-mini"}}
        },
        %{
          "identifier" => "MISSING",
          "model_routing" => %{"resolved" => %{"model" => "openai-codex/gpt-5.5"}}
        }
      ]

      roles = ModelUsage.model_roles(runs)

      assert roles.active.model == "openrouter/kimi"
      assert Enum.any?(roles.historical, &(&1.model == "openai-codex/gpt-5.4-mini"))
    end
  end

  describe "integration: full workflow" do
    test "aggregation across multiple attempts with provider switches" do
      # Simulates: RON-29 had 2 codex attempts, then switched to OpenRouter
      running = [
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 10:00:00Z],
          "model_routing" => %{
            "status" => "honored",
            "resolved" => %{"adapter" => "pi", "model" => "openrouter/moonshotai/kimi-k2.7-code"},
            "candidates" => [
              %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"},
              %{"adapter" => "pi", "model" => "openrouter/moonshotai/kimi-k2.7-code"}
            ]
          },
          "tokens" => %{"total_tokens" => 3000}
        },
        %{
          "identifier" => "RON-59",
          "started_at" => ~U[2026-06-29 10:05:00Z],
          "model_routing" => %{
            "status" => "honored",
            "resolved" => %{"adapter" => "pi", "model" => "openrouter/moonshotai/kimi-k2.7-code"},
            "candidates" => [
              %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"},
              %{"adapter" => "pi", "model" => "openrouter/moonshotai/kimi-k2.7-code"}
            ]
          },
          "tokens" => %{"total_tokens" => 2000}
        },
        %{
          "identifier" => "BEI-49",
          "started_at" => ~U[2026-06-29 10:10:00Z],
          "model_routing" => %{
            "status" => "honored",
            "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"}
          },
          "tokens" => %{"total_tokens" => 1500}
        },
        %{
          "identifier" => "MEM-74",
          "started_at" => ~U[2026-06-29 10:15:00Z],
          "model_routing" => %{
            "status" => "honored",
            "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.5"}
          },
          "tokens" => %{"total_tokens" => 2500}
        }
      ]

      archived = [
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 09:00:00Z],
          "finished_at" => ~U[2026-06-29 09:30:00Z],
          "exit_reason" => "exited: failure",
          "model_routing" => %{
            "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"}
          },
          "tokens" => %{"total_tokens" => 1200}
        },
        %{
          "identifier" => "RON-29",
          "started_at" => ~U[2026-06-29 09:35:00Z],
          "finished_at" => ~U[2026-06-29 09:55:00Z],
          "exit_reason" => "exited: failure",
          "model_routing" => %{
            "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"}
          },
          "tokens" => %{"total_tokens" => 800}
        },
        %{
          "identifier" => "RON-59",
          "started_at" => ~U[2026-06-29 09:00:00Z],
          "finished_at" => ~U[2026-06-29 09:40:00Z],
          "exit_reason" => "exited: failure",
          "model_routing" => %{
            "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"}
          },
          "tokens" => %{"total_tokens" => 1500}
        },
        %{
          "identifier" => "RON-59",
          "started_at" => ~U[2026-06-29 09:45:00Z],
          "finished_at" => ~U[2026-06-29 09:55:00Z],
          "exit_reason" => "exited: failure",
          "model_routing" => %{
            "resolved" => %{"adapter" => "pi", "model" => "openai-codex/gpt-5.4-mini"}
          },
          "tokens" => %{"total_tokens" => 500}
        }
      ]

      # Aggregate all runs
      usage = ModelUsage.aggregate(running, archived)

      assert usage.total_runs == 8
      assert usage.total_tokens == 13_000

      # 2 of 8 total runs are active codex (BEI-49, MEM-74)
      codex_consumers = ModelUsage.active_codex_consumers(running)
      assert length(codex_consumers) == 2
      assert Enum.map(codex_consumers, & &1.identifier) |> Enum.sort() == ["BEI-49", "MEM-74"]

      # Check RON-29 model roles - should show switch from codex to openrouter
      ron29_runs = Enum.filter(running ++ archived, &(&1["identifier"] == "RON-29"))
      ron29_roles = ModelUsage.model_roles(ron29_runs)

      assert ron29_roles.active.model == "openrouter/moonshotai/kimi-k2.7-code"
      assert length(ron29_roles.historical) == 1
      assert hd(ron29_roles.historical).model == "openai-codex/gpt-5.4-mini"
      assert hd(ron29_roles.historical).provider == "codex"

      # RON-29 fallback candidates should NOT include models already used historically
      # (gpt-5.4-mini was used in prior attempts, so it stays in historical, not fallback)
      ron29_fallback_models = Enum.map(ron29_roles.fallback, & &1.model)
      refute "openai-codex/gpt-5.4-mini" in ron29_fallback_models

      # RON-59 model roles - similar switch pattern
      ron59_runs = Enum.filter(running ++ archived, &(&1["identifier"] == "RON-59"))
      ron59_roles = ModelUsage.model_roles(ron59_runs)

      assert ron59_roles.active.model == "openrouter/moonshotai/kimi-k2.7-code"
      assert length(ron59_roles.historical) == 1
      assert hd(ron59_roles.historical).model == "openai-codex/gpt-5.4-mini"
    end

    test "codex subscription impact is obvious in active state" do
      # Mix of codex and openrouter active runs
      running = [
        codex_run("BEI-49", "openai-codex/gpt-5.4-mini", 1500),
        codex_run("BEI-29", "openai-codex/gpt-5.4-mini", 2000),
        codex_run("MEM-74", "openai-codex/gpt-5.5", 2500),
        openrouter_run("RON-29", "openrouter/moonshotai/kimi-k2.7-code", 3000),
        openrouter_run("RON-59", "openrouter/moonshotai/kimi-k2.7-code", 2000),
        openrouter_run("RON-48", "openrouter/moonshotai/kimi-k2.7-code", 1000)
      ]

      usage = ModelUsage.aggregate(running, [])

      # Codex: 3 runs (50%), OpenRouter: 3 runs (50%)
      assert usage.codex_pct == 50.0
      assert usage.openrouter_pct == 50.0

      # Active codex consumers clearly identified
      consumers = ModelUsage.active_codex_consumers(running)
      assert length(consumers) == 3
      assert Enum.map(consumers, & &1.identifier) |> Enum.sort() == ["BEI-29", "BEI-49", "MEM-74"]
    end
  end

  # --- Helpers ---

  defp codex_run(identifier, model, tokens) do
    run_with_model_routing(identifier, model, tokens)
  end

  defp openrouter_run(identifier, model, tokens) do
    run_with_model_routing(identifier, model, tokens)
  end

  defp run_with_model_routing(identifier, model, tokens) do
    %{
      "identifier" => identifier,
      "started_at" => ~U[2026-06-29 10:00:00Z],
      "model_routing" => %{
        "status" => "honored",
        "resolved" => %{"adapter" => "pi", "model" => model}
      },
      "tokens" => %{"total_tokens" => tokens}
    }
  end
end
