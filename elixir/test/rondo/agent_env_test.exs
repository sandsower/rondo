defmodule Rondo.Agent.EnvTest do
  use ExUnit.Case, async: true

  alias Rondo.Agent.Env

  test "scrubs ambient tracker and repository credentials by default" do
    env = Env.port_env()

    assert {~c"LINEAR_API_KEY", false} in env
    assert {~c"GITHUB_TOKEN", false} in env
    assert {~c"GH_TOKEN", false} in env
    assert {~c"SSH_AUTH_SOCK", false} in env
  end

  test "supports explicit allowlist and explicit agent env overrides" do
    env = Env.port_env(agent_env_allowlist: ["GITHUB_TOKEN"], agent_env: %{"RONDO_SAFE" => "1"})

    refute {~c"GITHUB_TOKEN", false} in env
    assert {~c"LINEAR_API_KEY", false} in env
    assert {~c"RONDO_SAFE", ~c"1"} in env
  end
end
