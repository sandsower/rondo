defmodule Rondo.ModelRoutingTest do
  use Rondo.TestSupport

  alias Rondo.ModelRouting

  test "source-contract hints outrank provider hints and use repo tier overrides" do
    assert %{
             status: :honored,
             requested_tier: "light",
             resolved: %{adapter: "pi", model: "openai/gpt-4o-mini"}
           } =
             ModelRouting.resolve(
               source_contract: %{model_routing: %{"tier" => "light"}},
               model_routing_hints: %{"model" => "provider-model"},
               repo_model_routing: %{tiers: %{light: [%{adapter: "pi", model: "openai/gpt-4o-mini"}]}}
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
             resolved: %{adapter: nil, model: "routed-model"}
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
end
