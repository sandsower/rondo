defmodule Rondo.ChildLaunchCLIEnvironmentTest do
  use Rondo.TestSupport

  alias Rondo.Agent.{ChildHome, ChildLaunchPolicy}
  alias Rondo.Codex.CLI, as: CodexCLI
  alias Rondo.Pi.CLI, as: PiCLI

  test "Claude receives the protected environment on initial and resume invocation" do
    assert_cli_environment(:claude_code)
  end

  test "Codex receives the protected environment on initial and resume invocation" do
    assert_cli_environment(:codex)
  end

  test "Pi receives the protected environment on initial and resume invocation" do
    assert_cli_environment(:pi)
  end

  defp assert_cli_environment(adapter) do
    root = Path.join(System.tmp_dir!(), "rondo-child-cli-env-#{adapter}-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "MT-ENV")
    binary = Path.join(root, "fake-#{adapter}")
    trace = Path.join(root, "trace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(binary, fake_cli_script(adapter, trace))
    File.chmod!(binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      claude_command: binary,
      codex_command: binary,
      pi_command: binary
    )

    adapter_name = to_string(adapter)
    model = model(adapter)
    provider_env = provider_env(adapter)

    inherited_env =
      System.get_env()
      |> Map.put("LINEAR_API_KEY", "tracker-secret")
      |> Map.put(provider_env, "provider-secret")

    assert {:ok, envelope} =
             ChildLaunchPolicy.resolve(
               run_mode: "unattended-auto",
               dispatch_origin: :daemon,
               adapter: adapter_name,
               model: model,
               isolation_baseline: :os_credential_isolated,
               run_dir: Path.join(root, "run"),
               inherited_env: inherited_env
             )

    assert :ok = ChildHome.prepare(envelope)
    assert {:ok, _result} = run_cli(adapter, workspace, envelope, nil)
    assert {:ok, _result} = run_cli(adapter, workspace, envelope, previous_ref(adapter))

    output = File.read!(trace)
    assert output =~ "HOME=#{envelope.home_path}"
    assert output =~ "LINEAR=unset"
    assert output =~ "PROVIDER=provider-secret"
  end

  defp run_cli(:claude_code, workspace, envelope, nil), do: ClaudeCLI.run("work", workspace, child_launch_envelope: envelope)
  defp run_cli(:claude_code, workspace, envelope, _previous), do: ClaudeCLI.resume("claude-session", "continue", workspace, child_launch_envelope: envelope)
  defp run_cli(:codex, workspace, envelope, nil), do: CodexCLI.run("work", workspace, child_launch_envelope: envelope)
  defp run_cli(:codex, workspace, envelope, previous), do: CodexCLI.resume(previous, "continue", workspace, child_launch_envelope: envelope)
  defp run_cli(:pi, workspace, envelope, nil), do: PiCLI.run("work", workspace, child_launch_envelope: envelope)
  defp run_cli(:pi, workspace, envelope, previous), do: PiCLI.resume(previous, "continue", workspace, child_launch_envelope: envelope)

  defp previous_ref(:codex), do: "codex-thread"
  defp previous_ref(:pi), do: "pi-session"
  defp previous_ref(:claude_code), do: "claude-session"

  defp model(:claude_code), do: "claude-sonnet"
  defp model(:codex), do: "gpt-5.4"
  defp model(:pi), do: "openrouter/deepseek/deepseek-chat"

  defp provider_env(:claude_code), do: "ANTHROPIC_API_KEY"
  defp provider_env(:codex), do: "OPENAI_API_KEY"
  defp provider_env(:pi), do: "OPENROUTER_API_KEY"

  defp fake_cli_script(adapter, trace) do
    provider_env = provider_env(adapter)

    events =
      case adapter do
        :claude_code ->
          ~s(echo '{"type":"result","subtype":"success","session_id":"claude-session","usage":{"input_tokens":1,"output_tokens":1}}')

        :codex ->
          ~s(echo '{"type":"thread.started","thread_id":"codex-thread"}'; echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}')

        :pi ->
          ~s(echo '{"type":"session","version":3,"id":"pi-session"}'; echo '{"type":"agent_end","messages":[]}')
      end

    """
    #!/bin/sh
    printf 'HOME=%s\nLINEAR=%s\nPROVIDER=%s\n' "$HOME" "${LINEAR_API_KEY-unset}" "${#{provider_env}-unset}" >> "#{trace}"
    #{events}
    """
  end
end
