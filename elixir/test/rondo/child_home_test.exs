defmodule Rondo.ChildHomeTest do
  use ExUnit.Case, async: true

  alias Rondo.Agent.{ChildHome, ChildLaunchPolicy}

  test "prepares a private synthetic home and replaces inherited environment" do
    root = Path.join(System.tmp_dir!(), "rondo-child-home-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "supervised-auto",
               dispatch_origin: :run_once,
               unsafe_bypass: true,
               adapter: "codex",
               model: "gpt-5.4",
               isolation_baseline: :env_home_scoped,
               run_dir: root,
               inherited_env: %{
                 "PATH" => "/usr/bin",
                 "OPENAI_API_KEY" => "provider-secret",
                 "LINEAR_API_KEY" => "tracker-secret",
                 "GH_TOKEN" => "github-secret"
               }
             )

    assert :ok = ChildHome.prepare(envelope)
    assert File.dir?(envelope.home_path)
    assert File.stat!(envelope.home_path).mode |> Bitwise.band(0o777) == 0o700

    port_env =
      envelope
      |> ChildHome.port_environment(%{"PATH" => "/bad", "LINEAR_API_KEY" => "tracker-secret", "GH_TOKEN" => "github-secret"})
      |> Map.new(fn {name, value} -> {to_string(name), if(value == false, do: false, else: to_string(value))} end)

    assert port_env["LINEAR_API_KEY"] == false
    assert port_env["GH_TOKEN"] == false
    assert port_env["HOME"] == envelope.home_path
    assert port_env["OPENAI_API_KEY"] == "provider-secret"
  end

  test "the same run and adapter resolve the same home for resume" do
    opts = [
      run_mode: "supervised-auto",
      dispatch_origin: :run_once,
      unsafe_bypass: true,
      adapter: "pi",
      model: "openrouter/deepseek/deepseek-chat",
      isolation_baseline: :env_home_scoped,
      run_dir: "/tmp/rondo-resume-home",
      inherited_env: %{}
    ]

    assert {:ok, first} = ChildLaunchPolicy.resolve(opts)
    assert {:ok, resumed} = ChildLaunchPolicy.resolve(Keyword.put(opts, :previous_run_ref, %{provider_ref: "session-1"}))
    assert first.home_path == resumed.home_path
  end
end
