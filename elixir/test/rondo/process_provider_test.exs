defmodule Rondo.ProcessProviderTest do
  use Rondo.TestSupport

  alias Rondo.ProcessProvider
  alias Rondo.ProcessProvider.Native

  defmodule ErrorProvider do
    def select_gates(_opts), do: {:error, :provider_unavailable}
  end

  defmodule LegacyListProvider do
    def select_gates(_opts) do
      {:ok, [%{name: "legacy", command: "mix test", timeout_ms: 1_000, action_classes: ["read"]}]}
    end
  end

  test "native provider exposes current workflow gates and unsupported rich features" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gates: [%{name: "unit", command: "mix test", timeout_ms: 120_000}],
      claude_model: "claude-test",
      claude_allowed_tools: ["Read", "Bash"]
    )

    assert Native.id() == "native"
    assert Native.capabilities().gate_selection == "native_flat_gates"
    assert Native.capabilities().guide_selection == "unsupported"

    assert {:ok,
            %{
              gates: [%{name: "unit", command: "mix test", timeout_ms: 120_000, action_classes: ["read"]}],
              selected: [%{name: "unit", reason: reason}],
              skipped: [],
              warnings: []
            }} = Native.select_gates()

    assert reason =~ "WORKFLOW.md"

    assert {:ok, []} = Native.select_guides()
    assert {:ok, []} = Native.proof_requirements()

    assert Native.model_routing_hints() == %{
             agent_adapter: "claude_code",
             claude_allowed_tools: ["Read", "Bash"],
             claude_model: "claude-test"
           }
  end

  test "native provider renders the existing workflow prompt" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}: {{ issue.title }}")

    issue = %Issue{id: "1", identifier: "RON-1", title: "Add seam", state: "Todo"}

    assert Native.prompt(issue) == "Ticket RON-1: Add seam"
    assert ProcessProvider.prompt(Native, issue) == "Ticket RON-1: Add seam"
  end

  test "native provider reports degraded probe metadata when action policy command is unavailable" do
    write_workflow_file!(Workflow.workflow_file_path(), action_policy_command: "rondo-missing-beislid")

    assert %{status: :degraded, checks: %{action_policy: :missing, guide_selection: :unsupported}} = Native.probe()
  end

  test "native provider evaluates action policy through configured evaluator" do
    write_workflow_file!(Workflow.workflow_file_path(), action_policy_command: fake_evaluator("allow"))

    assert {:ok, %{"decision" => "allow", "action" => "file.read"}} = Native.evaluate_action_policy("file.read", ["read"])
  end

  test "provider facade resolves native and custom providers" do
    write_workflow_file!(Workflow.workflow_file_path(), process_provider_kind: "native")

    assert ProcessProvider.provider_module() == Native
    assert ProcessProvider.provider_module(:native) == Native
    assert ProcessProvider.provider_module("native") == Native
    assert ProcessProvider.provider_module(__MODULE__) == __MODULE__
  end

  test "provider facade helpers expose defaults, normalized selections, and errors" do
    assert ProcessProvider.probe_result(:ok) == %{status: :ok, checks: %{}}

    assert {:ok,
            %{
              gates: [%{name: "legacy"}],
              selected: [%{name: "legacy", reason: "selected by process provider"}],
              skipped: [],
              warnings: []
            }} = ProcessProvider.select_gate_selection(LegacyListProvider)

    assert [%{name: "legacy"}] = ProcessProvider.select_gates!(LegacyListProvider)
    assert %{gates: []} = ProcessProvider.select_gate_selection!()

    assert_raise RuntimeError, ~r/process_provider_gate_selection_failed: :provider_unavailable/, fn ->
      ProcessProvider.select_gates!(ErrorProvider)
    end

    evaluator = ProcessProvider.action_policy_evaluator()

    assert {:ok, %{"decision" => "allow", "action" => "file.read"}} =
             evaluator.("file.read", ["read"], command: fake_evaluator("allow"))
  end

  defp fake_evaluator(decision) do
    evaluator_dir = Path.join(System.tmp_dir!(), "rondo-process-provider-evaluator-#{System.unique_integer([:positive])}")
    path = Path.join(evaluator_dir, "beislid")
    File.mkdir_p!(Path.dirname(path))

    script = ~s'''
    #!/bin/sh
    action=""
    classes=""
    mode=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --action) action="$2"; shift 2 ;;
        --class) classes="${classes}${classes:+,}$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '{"decision":"#{decision}","action":"%s","classes":["read"],"mode":"%s"}' "$action" "$mode"
    '''

    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end
end
