defmodule Rondo.LiveLinearClaudeE2ETest do
  @moduledoc """
  Opt-in live end-to-end profile: Linear issue fetch, workspace prep, Claude
  subprocess, tracker state transition, and cleanup against a disposable
  `[rondo-e2e]` issue in a dedicated test team/project.

  Run via `make e2e` with:

      RONDO_RUN_LIVE_E2E=1
      LINEAR_API_KEY=<real key>
      RONDO_E2E_LINEAR_TEAM=<team key, e.g. RONT>
      RONDO_E2E_LINEAR_PROJECT=<project name in that team>

  Never enabled by default or in CI. See README "Live end-to-end test".
  """

  use Rondo.TestSupport

  alias Rondo.LiveE2E
  alias Rondo.RunOnce

  @moduletag :live_e2e
  @moduletag timeout: 600_000

  if !LiveE2E.enabled?() do
    # ExUnit reports skipped tests without their skip reason, so print it when
    # this module is explicitly targeted (e.g. `mix test --only live_e2e`).
    if :live_e2e in ExUnit.configuration()[:include] do
      IO.puts(:stderr, LiveE2E.skip_reason())
    end

    @moduletag skip: LiveE2E.skip_reason()
  end

  test "linear + claude run-once round trip with disposable issue" do
    context = load_context!()

    # The Rondo.TestSupport setup wrote a placeholder tracker token ("token").
    # The LiveE2E helpers default to Rondo.Linear.Client.graphql/2, which reads
    # that workflow, so point it at the real key before the first live call.
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "$LINEAR_API_KEY")

    team = resolve!(LiveE2E.resolve_team(context.team_key), "resolve team #{context.team_key}")

    project =
      resolve!(
        LiveE2E.resolve_project(context.project_name, team),
        "resolve project #{context.project_name} in team #{context.team_key}"
      )

    issue = resolve!(LiveE2E.create_issue(%{team: team, project: project}), "create disposable issue")
    on_exit(fn -> LiveE2E.cleanup_issue(issue) end)

    workspace_root = configure_live_workflow!(context, project)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    run_result = RunOnce.run(issue.id)

    debug_context = """
    issue=#{issue.identifier} url=#{issue.url}
    workspace_root=#{workspace_root}
    run_result=#{inspect(run_result, pretty: true)}
    """

    assert :ok == run_result, "run-once failed; #{debug_context}"

    marker_path = Path.join([workspace_root, issue.identifier, LiveE2E.marker_file_name()])

    assert File.exists?(marker_path),
           "expected Claude to create workspace marker #{marker_path}; #{debug_context}"

    assert marker_path |> File.read!() |> String.trim() == LiveE2E.marker_content(),
           "unexpected marker content in #{marker_path}; #{debug_context}"

    state =
      case LiveE2E.fetch_issue_state(issue.id) do
        {:ok, state} ->
          state

        {:error, reason} ->
          flunk("fetching final issue state failed: #{inspect(reason, pretty: true)}; #{debug_context}")
      end

    assert state == LiveE2E.in_progress_state_name(),
           "expected tracker state #{LiveE2E.in_progress_state_name()}, got #{state}; #{debug_context}"
  end

  defp load_context! do
    case LiveE2E.load_context() do
      {:ok, context} ->
        context

      {:error, {:missing_env, missing}} ->
        flunk("live E2E enabled but missing environment variables: #{Enum.join(missing, ", ")}")

      {:error, :placeholder_linear_api_key} ->
        flunk("live E2E enabled but LINEAR_API_KEY is the test placeholder; export a real key")

      {:error, {:action_policy_command_missing, var}} ->
        flunk(
          "live E2E requires beislid (the action-policy evaluator) to be installed on PATH. " <>
            "Install beislid, or set #{var}=#{LiveE2E.action_policy_fake_value()} to use the " <>
            "allow-all test stub (unsafe — every action will be approved without evaluation)."
        )

      {:error, {:invalid_agent_adapter, value, accepted}} ->
        flunk("RONDO_E2E_AGENT_ADAPTER=#{value} is not valid; accepted values: #{Enum.join(accepted, ", ")}")

      {:error, {:agent_cli_missing, command, env_var}} ->
        flunk(
          "live E2E: agent CLI #{inspect(command)} not found on PATH. " <>
            "Install it or set #{env_var} to point to the binary."
        )
    end
  end

  defp resolve!(result, step) do
    case result do
      {:ok, value} -> value
      {:error, reason} -> flunk("live E2E setup failed at #{step}: #{inspect(reason, pretty: true)}")
    end
  end

  # Rewrites the per-test temp WORKFLOW.md (created by Rondo.TestSupport) with
  # live values. The tracker project_slug scopes every Rondo query to the test
  # project, so the normal Rondo project is never read or mutated.
  #
  # The adapter section (claude: or pi:) is determined by context.agent_adapter
  # via LiveE2E.workflow_overrides_for_adapter/1, keeping adapter-specific keys
  # out of the shared overrides list.
  defp configure_live_workflow!(context, project) do
    workspace_root =
      Path.join(System.tmp_dir!(), "rondo-live-e2e-workspaces-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)

    adapter_overrides = LiveE2E.workflow_overrides_for_adapter(context)

    overrides =
      Keyword.merge(adapter_overrides,
        tracker_api_token: "$LINEAR_API_KEY",
        tracker_project_slug: project.slug_id,
        workspace_root: workspace_root,
        hook_after_create: "git init --quiet .",
        gates: nil,
        prompt: live_prompt()
      )

    overrides =
      case context.action_policy_command do
        # :fake means use the TestSupport allow-all stub; omit the override so
        # write_workflow_file!/2 picks up its default_action_policy_command().
        :fake -> overrides
        command -> Keyword.put(overrides, :action_policy_command, command)
      end

    write_workflow_file!(Workflow.workflow_file_path(), overrides)
    workspace_root
  end

  defp live_prompt do
    """
    You are running inside Rondo's live end-to-end test for issue {{ issue.identifier }}.

    Perform exactly one task: create a file named `#{LiveE2E.marker_file_name()}` in the
    current working directory containing exactly the line `#{LiveE2E.marker_content()}`.

    Do not modify any tracker or Linear state. Do not create branches, commits, or any
    other files. Stop immediately after writing the file.
    """
  end
end
