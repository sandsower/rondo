defmodule Rondo.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias Rondo.AgentRunner
      alias Rondo.Claude.CLI, as: ClaudeCLI
      alias Rondo.CLI
      alias Rondo.Config
      alias Rondo.HttpServer
      alias Rondo.Linear.Client
      alias Rondo.Linear.Issue
      alias Rondo.Orchestrator
      alias Rondo.PromptBuilder
      alias Rondo.StatusDashboard
      alias Rondo.Tracker
      alias Rondo.Workflow
      alias Rondo.WorkflowStore
      alias Rondo.Workspace

      import Rondo.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "rondo-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(Rondo.WorkflowStore), do: Rondo.WorkflowStore.force_reload()
        stop_default_http_server()
        previous_openrouter_key = System.get_env("OPENROUTER_API_KEY")
        System.put_env("OPENROUTER_API_KEY", "rondo-test-openrouter-key")

        on_exit(fn ->
          stop_default_http_server()
          Workflow.clear_workflow_file_path()
          Application.delete_env(:rondo, :server_port_override)
          Application.delete_env(:rondo, :memory_tracker_issues)
          Application.delete_env(:rondo, :memory_tracker_recipient)
          restore_env("OPENROUTER_API_KEY", previous_openrouter_key)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    dir = Path.dirname(path)
    tmp_path = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive, :monotonic])}.tmp")

    File.mkdir_p!(dir)
    File.write!(tmp_path, workflow)
    File.rename!(tmp_path, path)

    if Process.whereis(Rondo.WorkflowStore) do
      Rondo.WorkflowStore.force_reload()
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    was_trapping = Process.flag(:trap_exit, true)

    try do
      stop_http_server_child()
      stop_http_server_endpoint()
      drain_exit_messages()
    after
      Process.flag(:trap_exit, was_trapping)
    end
  end

  defp stop_http_server_child do
    if supervisor = Process.whereis(Rondo.Supervisor) do
      if Process.alive?(supervisor) do
        try do
          _ = Supervisor.terminate_child(supervisor, Rondo.HttpServer)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp stop_http_server_endpoint do
    case Process.whereis(RondoWeb.Endpoint) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.unlink(pid)

        try do
          Supervisor.stop(pid, :shutdown, 2_000)
        catch
          :exit, _ -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          2_000 -> :ok
        end

        wait_for_http_server_shutdown()

      _ ->
        wait_for_http_server_shutdown()
    end
  end

  @spec wait_for_http_server_shutdown() :: :ok
  def wait_for_http_server_shutdown do
    wait_for_http_server_shutdown(fn -> is_nil(Rondo.HttpServer.bound_port()) end, 40, 25)
  end

  @spec wait_for_http_server_shutdown((-> boolean())) :: :ok
  def wait_for_http_server_shutdown(check_fun) when is_function(check_fun, 0) do
    wait_for_http_server_shutdown(check_fun, 40, 25)
  end

  @spec wait_for_http_server_shutdown((-> boolean()), non_neg_integer(), non_neg_integer()) :: :ok
  def wait_for_http_server_shutdown(check_fun, attempts, sleep_ms) when is_function(check_fun, 0) do
    wait_until(check_fun, attempts, sleep_ms)
  end

  defp wait_until(_fun, 0, _sleep_ms), do: raise("HTTP server did not shut down in time")

  defp wait_until(fun, attempts, sleep_ms) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(sleep_ms)
      wait_until(fun, attempts - 1, sleep_ms)
    end
  end

  defp drain_exit_messages do
    receive do
      {:EXIT, _pid, _reason} -> drain_exit_messages()
    after
      50 -> :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_repo: nil,
          tracker_state_label_prefix: nil,
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          tracker_label_filter: nil,
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "rondo_workspaces"),
          worker_max_concurrent_agents_per_host: 10,
          worker_ssh_hosts: [],
          max_concurrent_agents: 10,
          agent_adapter: "claude_code",
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          claude_command: "claude",
          claude_permission_mode: "bypassPermissions",
          claude_dangerously_skip_permissions: true,
          claude_max_turns: 50,
          claude_output_format: "stream-json",
          claude_model: nil,
          claude_allowed_tools: nil,
          claude_turn_timeout_ms: 3_600_000,
          claude_stall_timeout_ms: 300_000,
          pi_command: "pi",
          pi_turn_timeout_ms: 3_600_000,
          pi_stall_timeout_ms: 300_000,
          codex_command: "codex",
          codex_turn_timeout_ms: 3_600_000,
          codex_stall_timeout_ms: 300_000,
          action_policy_command: default_action_policy_command(),
          action_policy_run_mode: "unattended-auto",
          action_policy_policy_file: nil,
          release_loop_enabled: nil,
          release_loop_pr_review_source: nil,
          release_loop_pr_review_update: nil,
          release_loop_wait_interval_seconds: nil,
          release_loop_run_configured_gates_before_push: nil,
          release_loop_max_pr_risk_level: nil,
          release_loop_review_state: nil,
          release_loop_rework_state: nil,
          release_loop_merge_state: nil,
          release_loop_done_state: nil,
          release_loop_merge_mode: nil,
          release_loop_merge_method: nil,
          release_loop_merge_delete_branch: nil,
          process_provider_kind: "native",
          process_provider_required: false,
          process_provider_artifact_path: nil,
          model_routing: nil,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          gates: nil,
          gate_reuse_enabled: nil,
          clean_eval_enabled: nil,
          clean_eval_base_ref: nil,
          clean_eval_gates: nil,
          escalation_enabled: nil,
          escalation_tiers: nil,
          escalation_max_total_attempts: nil,
          escalation_token_budget: nil,
          escalation_report_repair_attempts: nil,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_repo = Keyword.get(config, :tracker_repo)
    tracker_state_label_prefix = Keyword.get(config, :tracker_state_label_prefix)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    tracker_label_filter = Keyword.get(config, :tracker_label_filter)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    agent_adapter = Keyword.get(config, :agent_adapter)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    claude_command = Keyword.get(config, :claude_command)
    claude_permission_mode = Keyword.get(config, :claude_permission_mode)
    claude_dangerously_skip_permissions = Keyword.get(config, :claude_dangerously_skip_permissions)
    claude_max_turns = Keyword.get(config, :claude_max_turns)
    claude_output_format = Keyword.get(config, :claude_output_format)
    claude_model = Keyword.get(config, :claude_model)
    claude_allowed_tools = Keyword.get(config, :claude_allowed_tools)
    claude_turn_timeout_ms = Keyword.get(config, :claude_turn_timeout_ms)
    claude_stall_timeout_ms = Keyword.get(config, :claude_stall_timeout_ms)
    pi_command = Keyword.get(config, :pi_command)
    pi_turn_timeout_ms = Keyword.get(config, :pi_turn_timeout_ms)
    pi_stall_timeout_ms = Keyword.get(config, :pi_stall_timeout_ms)
    codex_command = Keyword.get(config, :codex_command)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    action_policy_command = Keyword.get(config, :action_policy_command)
    action_policy_run_mode = Keyword.get(config, :action_policy_run_mode)
    action_policy_policy_file = Keyword.get(config, :action_policy_policy_file)
    release_loop_enabled = Keyword.get(config, :release_loop_enabled)
    release_loop_pr_review_source = Keyword.get(config, :release_loop_pr_review_source)
    release_loop_pr_review_update = Keyword.get(config, :release_loop_pr_review_update)
    release_loop_wait_interval_seconds = Keyword.get(config, :release_loop_wait_interval_seconds)
    release_loop_run_configured_gates_before_push = Keyword.get(config, :release_loop_run_configured_gates_before_push)
    release_loop_max_pr_risk_level = Keyword.get(config, :release_loop_max_pr_risk_level)
    release_loop_review_state = Keyword.get(config, :release_loop_review_state)
    release_loop_rework_state = Keyword.get(config, :release_loop_rework_state)
    release_loop_merge_state = Keyword.get(config, :release_loop_merge_state)
    release_loop_done_state = Keyword.get(config, :release_loop_done_state)
    release_loop_merge_mode = Keyword.get(config, :release_loop_merge_mode)
    release_loop_merge_method = Keyword.get(config, :release_loop_merge_method)
    release_loop_merge_delete_branch = Keyword.get(config, :release_loop_merge_delete_branch)

    release_loop_config = %{
      enabled: release_loop_enabled,
      pr_review_source: release_loop_pr_review_source,
      pr_review_update: release_loop_pr_review_update,
      wait_interval_seconds: release_loop_wait_interval_seconds,
      run_configured_gates_before_push: release_loop_run_configured_gates_before_push,
      max_pr_risk_level: release_loop_max_pr_risk_level,
      review_state: release_loop_review_state,
      rework_state: release_loop_rework_state,
      merge_state: release_loop_merge_state,
      done_state: release_loop_done_state,
      merge_mode: release_loop_merge_mode,
      merge_method: release_loop_merge_method,
      merge_delete_branch: release_loop_merge_delete_branch
    }

    process_provider_kind = Keyword.get(config, :process_provider_kind)
    process_provider_required = Keyword.get(config, :process_provider_required)
    process_provider_artifact_path = Keyword.get(config, :process_provider_artifact_path)
    model_routing = Keyword.get(config, :model_routing)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    gates = Keyword.get(config, :gates)
    gate_reuse_enabled = Keyword.get(config, :gate_reuse_enabled)
    clean_eval_enabled = Keyword.get(config, :clean_eval_enabled)
    clean_eval_base_ref = Keyword.get(config, :clean_eval_base_ref)
    clean_eval_gates = Keyword.get(config, :clean_eval_gates)
    escalation_enabled = Keyword.get(config, :escalation_enabled)
    escalation_tiers = Keyword.get(config, :escalation_tiers)
    escalation_max_total_attempts = Keyword.get(config, :escalation_max_total_attempts)
    escalation_token_budget = Keyword.get(config, :escalation_token_budget)
    escalation_report_repair_attempts = Keyword.get(config, :escalation_report_repair_attempts)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  repo: #{yaml_value(tracker_repo)}",
        "  state_label_prefix: #{yaml_value(tracker_state_label_prefix)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "  label_filter: #{yaml_value(tracker_label_filter)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_max_concurrent_agents_per_host, worker_ssh_hosts),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  adapter: #{yaml_value(agent_adapter)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "claude:",
        "  command: #{yaml_value(claude_command)}",
        "  permission_mode: #{yaml_value(claude_permission_mode)}",
        "  dangerously_skip_permissions: #{yaml_value(claude_dangerously_skip_permissions)}",
        "  max_turns: #{yaml_value(claude_max_turns)}",
        "  output_format: #{yaml_value(claude_output_format)}",
        "  model: #{yaml_value(claude_model)}",
        "  allowed_tools: #{yaml_value(claude_allowed_tools)}",
        "  turn_timeout_ms: #{yaml_value(claude_turn_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(claude_stall_timeout_ms)}",
        "pi:",
        "  command: #{yaml_value(pi_command)}",
        "  turn_timeout_ms: #{yaml_value(pi_turn_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(pi_stall_timeout_ms)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        "action_policy:",
        "  command: #{yaml_value(action_policy_command)}",
        "  run_mode: #{yaml_value(action_policy_run_mode)}",
        "  policy_file: #{yaml_value(action_policy_policy_file)}",
        release_loop_yaml(release_loop_config),
        "process_provider:",
        "  kind: #{yaml_value(process_provider_kind)}",
        "  required: #{yaml_value(process_provider_required)}",
        "  artifact_path: #{yaml_value(process_provider_artifact_path)}",
        model_routing_yaml(model_routing),
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        gates_yaml(gates),
        gate_reuse_yaml(gate_reuse_enabled),
        clean_eval_yaml(clean_eval_enabled, clean_eval_base_ref, clean_eval_gates),
        escalation_yaml(
          escalation_enabled,
          escalation_tiers,
          escalation_max_total_attempts,
          escalation_token_budget,
          escalation_report_repair_attempts
        ),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp default_action_policy_command do
    dir = Path.join(System.tmp_dir!(), "rondo-default-action-policy-#{System.unique_integer([:positive, :monotonic])}")
    path = Path.join(dir, "beislid-fake-allow")
    File.mkdir_p!(dir)

    File.write!(path, """
    #!/bin/sh
    action=""
    mode=""
    classes_json=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --action) action="$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        --class) classes_json="${classes_json}${classes_json:+,}\\\"$2\\\""; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '{"decision":"allow","action":"%s","mode":"%s","classes":[%s],"log_level":"info","requires_human":false,"reason":"test allow","matched_rules":[]}' "$action" "$mode" "$classes_json"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp model_routing_yaml(nil), do: nil

  defp model_routing_yaml(model_routing) when is_map(model_routing) do
    ["model_routing:" | yaml_block(model_routing, 2)]
    |> Enum.join("\n")
  end

  defp model_routing_yaml(model_routing), do: "model_routing: #{yaml_value(model_routing)}"

  defp yaml_block(map, indent) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> yaml_block_entry(to_string(key), value, indent) end)
  end

  defp yaml_block(list, indent) when is_list(list) do
    Enum.flat_map(list, fn
      value when is_map(value) ->
        case yaml_block(value, indent + 2) do
          [first | rest] -> [String.duplicate(" ", indent) <> "- " <> String.trim_leading(first) | rest]
          [] -> [String.duplicate(" ", indent) <> "- {}"]
        end

      value ->
        [String.duplicate(" ", indent) <> "- #{yaml_value(value)}"]
    end)
  end

  defp yaml_block_entry(key, value, indent) when is_map(value) or is_list(value) do
    [String.duplicate(" ", indent) <> "#{key}:" | yaml_block(value, indent + 2)]
  end

  defp yaml_block_entry(key, value, indent), do: [String.duplicate(" ", indent) <> "#{key}: #{yaml_value(value)}"]

  defp gates_yaml(nil), do: nil

  defp gates_yaml(gates) when is_list(gates) do
    ["gates:" | Enum.map(gates, &gate_yaml/1)]
    |> Enum.join("\n")
  end

  defp gates_yaml(gates), do: "gates: #{yaml_value(gates)}"

  defp gate_reuse_yaml(nil), do: nil
  defp gate_reuse_yaml(enabled), do: "gate_reuse:\n  enabled: #{yaml_value(enabled)}"

  defp gate_yaml(gate) when is_map(gate) or is_list(gate) do
    map = Map.new(gate)

    name = Map.get(map, :name) || Map.get(map, "name")
    command = Map.get(map, :command) || Map.get(map, "command")
    timeout_ms = Map.get(map, :timeout_ms) || Map.get(map, "timeout_ms")
    action_id = Map.get(map, :action_id) || Map.get(map, "action_id")
    action_classes = Map.get(map, :action_classes) || Map.get(map, "action_classes")

    [
      "  - name: #{yaml_value(name)}",
      "    command: #{yaml_value(command)}",
      gate_timeout_yaml(timeout_ms),
      gate_action_id_yaml(action_id),
      gate_action_classes_yaml(action_classes)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp gate_yaml(gate), do: "  - #{yaml_value(gate)}"

  defp gate_timeout_yaml(nil), do: nil
  defp gate_timeout_yaml(timeout_ms), do: "    timeout_ms: #{yaml_value(timeout_ms)}"

  defp gate_action_id_yaml(nil), do: nil
  defp gate_action_id_yaml(action_id), do: "    action_id: #{yaml_value(action_id)}"

  defp gate_action_classes_yaml(nil), do: nil
  defp gate_action_classes_yaml(action_classes), do: "    action_classes: #{yaml_value(action_classes)}"

  defp release_loop_yaml(config) when is_map(config) do
    if Enum.all?(Map.values(config), &is_nil/1) do
      nil
    else
      [
        "release_loop:",
        release_loop_line("enabled", Map.get(config, :enabled)),
        release_loop_line("pr_review_source", Map.get(config, :pr_review_source)),
        release_loop_line("pr_review_update", Map.get(config, :pr_review_update)),
        release_loop_line("wait_interval_seconds", Map.get(config, :wait_interval_seconds)),
        release_loop_line("run_configured_gates_before_push", Map.get(config, :run_configured_gates_before_push)),
        release_loop_line("max_pr_risk_level", Map.get(config, :max_pr_risk_level)),
        release_loop_line("review_state", Map.get(config, :review_state)),
        release_loop_line("rework_state", Map.get(config, :rework_state)),
        release_loop_line("merge_state", Map.get(config, :merge_state)),
        release_loop_line("done_state", Map.get(config, :done_state)),
        release_loop_closeout_yaml(
          Map.get(config, :merge_mode),
          Map.get(config, :merge_method),
          Map.get(config, :merge_delete_branch)
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end
  end

  defp release_loop_line(_key, nil), do: nil
  defp release_loop_line(key, value), do: "  #{key}: #{yaml_value(value)}"

  defp release_loop_closeout_yaml(nil, nil, nil), do: nil

  defp release_loop_closeout_yaml(merge_mode, merge_method, merge_delete_branch) do
    [
      "  closeout:",
      "    merge:",
      release_loop_closeout_line("mode", merge_mode),
      release_loop_closeout_line("method", merge_method),
      release_loop_closeout_line("delete_branch", merge_delete_branch)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp release_loop_closeout_line(_key, nil), do: nil
  defp release_loop_closeout_line(key, value), do: "      #{key}: #{yaml_value(value)}"

  defp worker_yaml(nil, []), do: nil
  defp worker_yaml(nil, nil), do: nil

  defp worker_yaml(max_concurrent_agents_per_host, ssh_hosts) do
    [
      "worker:",
      "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}",
      "  ssh_hosts: #{yaml_value(ssh_hosts || [])}"
    ]
    |> Enum.join("\n")
  end

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp clean_eval_yaml(nil, nil, nil), do: nil

  defp clean_eval_yaml(enabled, base_ref, gates) do
    [
      "clean_eval:",
      enabled != nil && "  enabled: #{yaml_value(enabled)}",
      base_ref && "  base_ref: #{yaml_value(base_ref)}",
      clean_eval_gates_yaml(gates)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp clean_eval_gates_yaml(nil), do: nil

  defp clean_eval_gates_yaml([]), do: "  gates: []"

  defp clean_eval_gates_yaml(gates) when is_list(gates) do
    entries =
      Enum.map_join(gates, "\n", fn gate ->
        gate
        |> gate_yaml()
        |> String.split("\n")
        |> Enum.map_join("\n", &("  " <> &1))
      end)

    "  gates:\n" <> entries
  end

  defp escalation_yaml(nil, nil, nil, nil, nil), do: nil

  defp escalation_yaml(enabled, tiers, max_total_attempts, token_budget, report_repair_attempts) do
    [
      "escalation:",
      escalation_line("enabled", enabled),
      escalation_line("tiers", tiers),
      escalation_line("max_total_attempts", max_total_attempts),
      escalation_line("token_budget", token_budget),
      escalation_line("report_repair_attempts", report_repair_attempts)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp escalation_line(_key, nil), do: nil
  defp escalation_line(key, value), do: "  #{key}: #{yaml_value(value)}"

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
