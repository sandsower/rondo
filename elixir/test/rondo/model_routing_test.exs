defmodule Rondo.ModelRoutingTest do
  use Rondo.TestSupport

  alias Rondo.ModelRouting

  test "source-contract broad hints override provider initial hints" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"},
             reason: reason
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               source_contract: %{model_routing: %{"tier" => "heavy", "adapter" => "pi"}},
               model_routing_hints: %{"initial" => %{"skill" => "kickoff", "tier" => "light"}},
               repo_model_routing: %{
                 tiers: %{
                   light: [%{adapter: "pi", model: "openai/gpt-4o-mini"}],
                   heavy: [%{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}]
                 }
               }
             )

    assert reason =~ "heavy"
  end

  test "source required invalid contextual tier blocks instead of inheriting lower-precedence routing" do
    assert %{
             status: :blocked,
             mode: :require,
             requested_tier: nil,
             candidates: [],
             resolved: nil,
             context: %{stage: "initial_spawn", skill: "kickoff"},
             reason: reason
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               source_contract: %{
                 model_routing_hints: %{
                   "initial" => %{"skill" => "kickoff", "tier" => "unknown-tier", "mode" => "require"}
                 }
               },
               model_routing_hints: %{"model" => "provider-model"},
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 tiers: %{standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}]}
               }
             )

    assert reason =~ "required initial_spawn/kickoff model routing hint could not be honored"
  end

  test "provider required invalid initial tier blocks instead of inheriting repo defaults" do
    assert %{
             status: :blocked,
             mode: :require,
             candidates: [],
             resolved: nil,
             context: %{stage: "initial_spawn", skill: "kickoff"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               model_routing_hints: %{"initial" => %{"skill" => "kickoff", "tier" => "unknown-tier", "required" => true}},
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 tiers: %{standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}]}
               }
             )
  end

  test "source-contract hints override provider hints by key and complementary hints merge" do
    assert %{
             status: :honored,
             requested_tier: "light",
             resolved: %{adapter: "pi", model: "provider-model"},
             reason: reason
           } =
             ModelRouting.resolve(
               source_contract: %{model_routing: %{"tier" => "light", "adapter" => "pi"}},
               model_routing_hints: %{"model" => "provider-model", "adapter" => "claude_code"},
               repo_model_routing: %{tiers: %{light: [%{adapter: "pi", model: "openai/gpt-4o-mini"}]}}
             )

    assert reason =~ "resolved tier light"
  end

  test "initial routing context prefers source-contract initial hints over broad provider hints" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"},
             context: %{stage: "initial_spawn", skill: "kickoff", phase: "context_discovery"},
             reason: reason
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               source_contract: %{
                 model_routing: %{
                   "initial" => %{
                     "skill" => "kickoff",
                     "phase" => "context_discovery",
                     "tier" => "heavy"
                   }
                 }
               },
               model_routing_hints: %{"model" => "provider-broad-model", "adapter" => "pi"},
               repo_model_routing: %{
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   heavy: [%{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}]
                 }
               }
             )

    assert reason =~ "initial_spawn"
    assert reason =~ "heavy"
  end

  test "initial routing context reads source-contract model_routing_hints" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"},
             context: %{stage: "initial_spawn", skill: "kickoff"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               source_contract: %{
                 model_routing_hints: %{
                   "initial" => %{"skill" => "kickoff", "tier" => "heavy"}
                 }
               },
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   heavy: [%{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}]
                 }
               }
             )
  end

  test "initial routing context reads source-contract runner_extensions model routing" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"},
             context: %{stage: "initial_spawn", skill: "kickoff"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               source_contract: %{
                 runner_extensions: %{
                   "model_routing" => %{
                     "initial" => %{"skill" => "kickoff", "capability_tier" => "heavy"}
                   }
                 }
               },
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   heavy: [%{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}]
                 }
               }
             )
  end

  test "initial spawn uses unambiguous stage-less step hints" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"},
             context: %{skill: "kickoff", phase: "context_discovery"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               model_routing_hints: %{
                 "steps" => ["not-a-map", %{"skill" => "kickoff", "phase" => "context_discovery", "tier" => "heavy"}]
               },
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   heavy: [%{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}]
                 }
               }
             )
  end

  test "initial spawn ignores ambiguous stage-less step and phase hints" do
    assert %{
             status: :honored,
             requested_tier: "standard",
             resolved: %{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               model_routing_hints: %{
                 "steps" => [%{"skill" => "kickoff", "tier" => "heavy"}],
                 "phases" => [%{"phase" => "review", "tier" => "frontier"}]
               },
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   heavy: [%{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}],
                   frontier: [%{adapter: "pi", model: "openrouter/frontier"}]
                 }
               }
             )
  end

  test "initial routing context prefers provider initial hints over repo defaults" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/z-ai/glm-5.2"},
             context: %{stage: "initial_spawn", skill: "kickoff"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: "initial_spawn"},
               model_routing_hints: %{
                 "initial" => %{"skill" => "kickoff", "tier" => "heavy"}
               },
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   heavy: [%{adapter: "pi", model: "openrouter/z-ai/glm-5.2"}]
                 }
               }
             )
  end

  test "repo step hints override repo defaults for initial spawn" do
    assert %{
             status: :honored,
             requested_tier: "frontier",
             resolved: %{adapter: "pi", model: "openrouter/frontier"},
             context: %{stage: "initial_spawn", skill: "kickoff", phase: "context_discovery"},
             reason: reason
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 step_hints: %{
                   initial: %{
                     skill: "kickoff",
                     phase: "context_discovery",
                     tier: "frontier"
                   }
                 },
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   frontier: [%{adapter: "pi", model: "openrouter/frontier"}]
                 }
               }
             )

    assert reason =~ "initial_spawn/kickoff/context_discovery"
    assert reason =~ "frontier"
  end

  test "source-contract hints override repo step hints" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/heavy"},
             context: %{stage: "initial_spawn", skill: "kickoff", phase: "context_discovery"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               source_contract: %{model_routing: %{"tier" => "heavy"}},
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 step_hints: %{
                   initial: %{
                     skill: "kickoff",
                     phase: "context_discovery",
                     tier: "frontier"
                   }
                 },
                 tiers: %{
                   heavy: [%{adapter: "pi", model: "openrouter/heavy"}],
                   frontier: [%{adapter: "pi", model: "openrouter/frontier"}]
                 }
               }
             )
  end

  test "repo step explicit model survives higher-precedence tier-only context" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: nil, model: "repo-step-model"},
             context: %{stage: "initial_spawn", skill: "kickoff"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               source_contract: %{
                 model_routing_hints: %{"initial" => %{"skill" => "kickoff", "tier" => "heavy"}}
               },
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 step_hints: %{
                   initial: %{
                     skill: "kickoff",
                     tier: "heavy",
                     model: "repo-step-model"
                   }
                 },
                 tiers: %{
                   heavy: [%{adapter: "pi", model: "repo-step-model"}],
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}]
                 }
               }
             )
  end

  test "non-matching repo step hints fall back to defaults" do
    assert %{
             status: :honored,
             requested_tier: "standard",
             resolved: %{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 step_hints: %{
                   steps: [
                     %{
                       stage: "turn",
                       skill: "review-response",
                       phase: "fresh_eyes",
                       tier: "frontier"
                     }
                   ]
                 },
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   frontier: [%{adapter: "pi", model: "openrouter/frontier"}]
                 }
               }
             )
  end

  test "non-initial routing context matches step and phase hint lists" do
    assert %{
             status: :honored,
             requested_tier: "frontier",
             resolved: %{adapter: "pi", model: "openrouter/frontier"},
             context: %{stage: "turn", skill: "ready_for_review", phase: "review"},
             reason: reason
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :turn, skill: "ready_for_review", phase: "review"},
               model_routing_hints: %{
                 "steps" => [
                   "not-a-map",
                   %{"skill" => "kickoff", "tier" => "heavy"},
                   %{"stage" => "turn", "phase" => "review", "tier" => "frontier"}
                 ],
                 "phases" => [%{"phase" => "review", "tier" => "heavy"}]
               },
               repo_model_routing: %{
                 tiers: %{
                   frontier: [%{adapter: "pi", model: "openrouter/frontier"}],
                   heavy: [%{adapter: "pi", model: "openrouter/heavy"}]
                 }
               }
             )

    assert reason =~ "turn/ready_for_review/review"
  end

  test "step matching requires every hint selector to match the routing context" do
    assert %{
             status: :honored,
             requested_tier: "standard",
             resolved: %{adapter: "pi", model: "openai-codex/gpt-5.4-mini"},
             context: %{stage: "turn", phase: "implementation"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :turn, phase: "implementation"},
               model_routing_hints: %{
                 "steps" => [%{"stage" => "turn", "phase" => "review", "tier" => "heavy"}],
                 "phases" => [%{"stage" => "turn", "phase" => "implementation", "tier" => "standard"}]
               },
               repo_model_routing: %{
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   heavy: [%{adapter: "pi", model: "openrouter/heavy"}]
                 }
               }
             )
  end

  test "phase list matching is used when no step list matches" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/heavy"},
             context: %{stage: "turn", phase: "submit"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :turn, phase: "submit"},
               model_routing_hints: %{
                 "steps" => [%{"phase" => "review", "tier" => "frontier"}],
                 "phases" => [%{"phase" => "submit", "tier" => "heavy"}]
               },
               repo_model_routing: %{
                 tiers: %{
                   frontier: [%{adapter: "pi", model: "openrouter/frontier"}],
                   heavy: [%{adapter: "pi", model: "openrouter/heavy"}]
                 }
               }
             )
  end

  test "context selectors normalize hyphen and underscore vocabulary" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/heavy"},
             context: %{stage: "turn", skill: "ready_for_review", phase: "context_discovery"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :turn, skill: "ready-for-review", phase: "context-discovery"},
               model_routing_hints: %{
                 "steps" => [
                   %{
                     "stage" => "turn",
                     "skill" => "ready_for_review",
                     "phase" => "context_discovery",
                     "tier" => "heavy"
                   }
                 ]
               },
               repo_model_routing: %{tiers: %{heavy: [%{adapter: "pi", model: "openrouter/heavy"}]}}
             )
  end

  test "blank context values normalize to nil" do
    assert %{
             status: :honored,
             context: %{stage: "turn"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :turn, phase: "   "},
               model_routing_hints: %{"steps" => [%{"stage" => "turn", "tier" => "heavy"}]},
               repo_model_routing: %{tiers: %{heavy: [%{adapter: "pi", model: "openrouter/heavy"}]}}
             )
  end

  test "initial context without metadata resolves without recording context" do
    refute Map.has_key?(
             ModelRouting.resolve(
               routing_context: %{stage: 1},
               model_routing_hints: %{"initial" => %{"tier" => "heavy"}},
               repo_model_routing: %{tiers: %{heavy: [%{adapter: "pi", model: "openrouter/heavy"}]}}
             ),
             :context
           )
  end

  test "repo floor can supply a tier when hints are absent" do
    assert %{
             status: :honored,
             mode: :prefer,
             requested_tier: nil,
             resolved: %{adapter: "claude_code", model: "sonnet"},
             reason: "resolved explicit model to claude_code/sonnet"
           } =
             ModelRouting.resolve(repo_model_routing: %{floor: %{tier: :standard, mode: :require}})
  end

  test "invalid repo candidates fall back to built-in candidates" do
    assert %{
             status: :honored,
             requested_tier: "standard",
             resolved: %{adapter: "claude_code", model: "sonnet"}
           } =
             ModelRouting.resolve(
               model_routing_hints: %{tier: "standard"},
               repo_model_routing: %{tiers: %{standard: [%{adapter: :pi, model: ""}, %{adapter: 123, model: nil}]}}
             )
  end

  test "explicit model accepts atom adapter and require aliases" do
    assert %{
             status: :honored,
             mode: :require,
             resolved: %{adapter: "pi", model: "frontier-model"},
             reason: "resolved explicit model to pi/frontier-model"
           } =
             ModelRouting.resolve(model_routing_hints: %{agent_adapter: :pi, model: "frontier-model", mode: :require, required: true})
  end

  test "nil repo routing and atom frontier tier use built-in candidates" do
    assert %{
             status: :honored,
             requested_tier: "frontier",
             resolved: %{adapter: "claude_code", model: "opus"}
           } =
             ModelRouting.resolve(model_routing_hints: %{tier: :frontier}, repo_model_routing: nil)
  end

  test "repo floor still raises contextual initial hints" do
    assert %{
             status: :fallback,
             requested_tier: "light",
             resolved: %{adapter: "claude_code", model: "sonnet"},
             context: %{stage: "initial_spawn", skill: "kickoff"},
             reason: reason
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               model_routing_hints: %{"initial" => %{"skill" => "kickoff", "tier" => "light"}},
               repo_model_routing: %{floor: %{tier: "standard", mode: "require"}}
             )

    assert reason =~ "repo require floor standard"
    assert reason =~ "initial_spawn"
  end

  test "invalid provider hints and context fall back to no routing" do
    assert %{
             status: :unsupported,
             requested_tier: nil,
             candidates: [],
             resolved: nil,
             reason: "no model routing hint resolved"
           } = ModelRouting.resolve(model_routing_hints: "bad", routing_context: %{stage: :turn})
  end

  test "invalid routing context is ignored" do
    assert %{
             status: :honored,
             requested_tier: "light",
             resolved: %{adapter: "claude_code", model: "haiku"}
           } = ModelRouting.resolve(model_routing_hints: %{tier: "light"}, routing_context: "bad")
  end

  test "default config path can resolve without explicit options" do
    assert %{status: status, mode: :prefer, candidates: candidates} = ModelRouting.resolve()
    assert status in [:honored, :unsupported]
    assert is_list(candidates)
  end

  test "context tier keeps explicit contextual model when supplied" do
    assert %{
             status: :honored,
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "explicit-heavy"},
             reason: "resolved initial_spawn/kickoff tier heavy to pi/explicit-heavy"
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :initial_spawn},
               model_routing_hints: %{
                 "initial" => %{
                   "skill" => "kickoff",
                   "tier" => "heavy",
                   "adapter" => "pi",
                   "model" => "explicit-heavy"
                 }
               }
             )
  end

  test "required boolean and prefer atom are accepted" do
    assert %{status: :blocked, mode: :require} =
             ModelRouting.resolve(model_routing_hints: %{tier: 123, required: true})

    assert %{status: :unsupported, mode: :prefer} =
             ModelRouting.resolve(model_routing_hints: %{tier: 123, mode: :prefer})
  end

  test "repo defaults supply routing when no hint is present" do
    assert %{
             status: :honored,
             mode: :require,
             requested_tier: "light",
             resolved: %{adapter: "pi", model: "openai/gpt-4o-mini"}
           } =
             ModelRouting.resolve(
               repo_model_routing: %{
                 defaults: %{tier: "light", mode: "require"},
                 tiers: %{light: [%{adapter: "pi", model: "openai/gpt-4o-mini"}]}
               }
             )
  end

  test "repo require floor upgrades lower tier with fallback status" do
    assert %{
             status: :fallback,
             requested_tier: "light",
             resolved: %{adapter: "claude_code", model: "sonnet"},
             reason: reason
           } =
             ModelRouting.resolve(
               model_routing_hints: %{"tier" => "light"},
               repo_model_routing: %{floor: %{tier: "standard", mode: "require"}}
             )

    assert reason =~ "repo require floor standard"
  end

  test "blocks require-mode hints when no candidate can be resolved" do
    assert %{
             status: :blocked,
             mode: :require,
             requested_tier: nil,
             candidates: [],
             resolved: nil,
             reason: reason
           } = ModelRouting.resolve(model_routing_hints: %{"mode" => "require", "tier" => "mystery"})

    assert reason =~ "required model routing hint could not be honored"
  end

  test "resolves an explicit model hint" do
    assert %{
             status: :honored,
             mode: :prefer,
             requested_tier: nil,
             candidates: [%{adapter: nil, model: "routed-model"}],
             resolved: %{adapter: nil, model: "routed-model"},
             reason: "resolved explicit model to routed-model"
           } = ModelRouting.resolve(model_routing_hints: %{"model" => "routed-model"})
  end

  test "resolves a tier hint to the built-in default candidate" do
    assert %{
             status: :honored,
             mode: :prefer,
             requested_tier: "light",
             candidates: [%{adapter: "claude_code", model: "haiku"} | _],
             resolved: %{adapter: "claude_code", model: "haiku"},
             reason: reason
           } = ModelRouting.resolve(model_routing_hints: %{"tier" => "light"})

    assert reason =~ "resolved tier light"
  end

  test "bulk implementation profile routes to OpenRouter light candidate" do
    assert %{
             status: :honored,
             mode: :prefer,
             profile: "bulk_implementation",
             requested_tier: "light",
             resolved: %{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"}
           } =
             ModelRouting.resolve(
               routing_profile: "bulk_implementation",
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 profiles: %{
                   bulk_implementation: %{tier: "light", mode: "prefer", adapter: "pi"}
                 },
                 tiers: %{
                   light: [%{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"}],
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}]
                 }
               }
             )
  end

  test "step hint overrides bulk profile default for stronger reasoning" do
    assert %{
             status: :honored,
             profile: "bulk_implementation",
             requested_tier: "heavy",
             resolved: %{adapter: "pi", model: "openrouter/heavy-model"},
             context: %{stage: "turn", skill: "implement", phase: "planning"}
           } =
             ModelRouting.resolve(
               routing_context: %{stage: :turn, skill: "implement", phase: :planning},
               routing_profile: "bulk_implementation",
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 profiles: %{bulk_implementation: %{tier: "light", mode: "prefer"}},
                 step_hints: %{
                   steps: [
                     %{stage: "turn", skill: "implement", phase: "planning", tier: "heavy"}
                   ]
                 },
                 tiers: %{
                   light: [%{adapter: "pi", model: "openrouter/light-model"}],
                   heavy: [%{adapter: "pi", model: "openrouter/heavy-model"}]
                 }
               }
             )
  end

  test "empty OpenRouter key is treated as missing" do
    previous_key = System.get_env("OPENROUTER_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "")

    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous_key) end)

    assert %{
             status: :unsupported,
             candidates: [],
             resolved: nil,
             reason: reason
           } =
             ModelRouting.resolve(
               model_routing_hints: %{"tier" => "light"},
               repo_model_routing: %{
                 tiers: %{light: [%{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"}]}
               }
             )

    assert reason =~ "OpenRouter API key missing"
  end

  test "non-string routing profile is ignored" do
    assert %{
             status: :honored,
             requested_tier: "standard",
             resolved: %{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}
           } =
             ModelRouting.resolve(
               routing_profile: 123,
               model_routing_hints: %{tier: "standard"},
               repo_model_routing: %{
                 defaults: %{tier: "light"},
                 profiles: %{"123" => %{tier: "heavy"}},
                 tiers: %{
                   standard: [%{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}],
                   light: [%{adapter: "pi", model: "openrouter/light-model"}]
                 }
               }
             )
  end

  test "missing OpenRouter key blocks bulk profile with a clear reason" do
    previous_key = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")

    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous_key) end)

    assert %{
             status: :unsupported,
             mode: :prefer,
             profile: "bulk_implementation",
             requested_tier: "light",
             candidates: [],
             resolved: nil,
             reason: reason
           } =
             ModelRouting.resolve(
               routing_profile: "bulk_implementation",
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 profiles: %{bulk_implementation: %{tier: "light", mode: "prefer"}},
                 tiers: %{light: [%{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"}]}
               }
             )

    assert reason =~ "OpenRouter API key missing"
  end

  test "missing OpenRouter key blocks require-mode profile" do
    previous_key = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")

    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous_key) end)

    assert %{
             status: :blocked,
             mode: :require,
             profile: "bulk_implementation",
             reason: reason
           } =
             ModelRouting.resolve(
               routing_profile: "bulk_implementation",
               repo_model_routing: %{
                 defaults: %{tier: "standard", mode: "prefer"},
                 profiles: %{bulk_implementation: %{tier: "light", mode: "require"}},
                 tiers: %{light: [%{adapter: "pi", model: "openrouter/deepseek/deepseek-chat"}]}
               }
             )

    assert reason =~ "OpenRouter API key missing"
  end

  test "missing OpenRouter key does not block mixed tier with a non-OpenRouter candidate" do
    previous_key = System.get_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")

    on_exit(fn -> restore_env("OPENROUTER_API_KEY", previous_key) end)

    assert %{
             status: :honored,
             requested_tier: "standard",
             resolved: %{adapter: "pi", model: "openai-codex/gpt-5.4-mini"}
           } =
             ModelRouting.resolve(
               model_routing_hints: %{"tier" => "standard"},
               repo_model_routing: %{
                 tiers: %{
                   standard: [
                     %{adapter: "pi", model: "openai-codex/gpt-5.4-mini"},
                     %{adapter: "pi", model: "openrouter/moonshotai/kimi-k2.7-code"}
                   ]
                 }
               }
             )
  end
end
