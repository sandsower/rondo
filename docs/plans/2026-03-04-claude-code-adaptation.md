# Claude Code adaptation implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the Codex JSON-RPC app-server integration with Claude Code's subprocess model (`claude -p` + `--output-format stream-json`).

**Architecture:** Fork the existing Elixir code in-place. Delete `codex/` modules, add `claude/` modules for subprocess management and stream parsing, update config schema, rename all `codex_*` fields to `claude_*` throughout orchestrator and tests.

**Tech Stack:** Elixir/OTP, existing deps (req, jason, yaml_elixir, solid, nimble_options). No new deps needed.

---

### Task 1: Config schema -- remove Codex fields, add Claude Code fields

**Files:**
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Modify: `elixir/test/support/test_support.exs`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

**Step 1: Update config.ex -- remove Codex-specific defaults and schema**

Remove these module attributes and their NimbleOptions entries:
- `@default_codex_command` -- replace with `@default_claude_command "claude"`
- `@default_codex_turn_timeout_ms` -- replace with `@default_claude_turn_timeout_ms 3_600_000`
- `@default_codex_read_timeout_ms` -- delete entirely (no handshake)
- `@default_codex_stall_timeout_ms` -- replace with `@default_claude_stall_timeout_ms 300_000`
- `@default_codex_approval_policy` -- delete (replaced by permission_mode)
- `@default_codex_thread_sandbox` -- delete (no equivalent)

Add new defaults:
```elixir
@default_claude_command "claude"
@default_claude_permission_mode "bypassPermissions"
@default_claude_dangerously_skip_permissions true
@default_claude_max_turns 50
@default_claude_output_format "stream-json"
@default_claude_turn_timeout_ms 3_600_000
@default_claude_stall_timeout_ms 300_000
```

**Step 2: Update the NimbleOptions schema**

Replace the `codex:` key in `@workflow_options_schema` with `claude:`:
```elixir
claude: [
  type: :map,
  default: %{},
  keys: [
    command: [type: :string, default: @default_claude_command],
    permission_mode: [type: :string, default: @default_claude_permission_mode],
    dangerously_skip_permissions: [type: :boolean, default: @default_claude_dangerously_skip_permissions],
    max_turns: [type: :pos_integer, default: @default_claude_max_turns],
    output_format: [type: :string, default: @default_claude_output_format],
    model: [type: {:or, [:string, nil]}, default: nil],
    allowed_tools: [type: {:or, [{:list, :string}, nil]}, default: nil],
    turn_timeout_ms: [type: :integer, default: @default_claude_turn_timeout_ms],
    stall_timeout_ms: [type: :integer, default: @default_claude_stall_timeout_ms]
  ]
]
```

**Step 3: Update typed getter functions**

Rename and update these functions:
- `codex_command/0` -> `claude_command/0` -- reads from `[:claude, :command]`
- `codex_turn_timeout_ms/0` -> `claude_turn_timeout_ms/0`
- `codex_stall_timeout_ms/0` -> `claude_stall_timeout_ms/0`
- Delete: `codex_approval_policy/0`, `codex_thread_sandbox/0`, `codex_turn_sandbox_policy/1`, `codex_read_timeout_ms/0`, `codex_runtime_settings/1`
- Delete: `resolve_codex_approval_policy/0`, `resolve_codex_thread_sandbox/0`, `resolve_codex_turn_sandbox_policy/1`, `default_codex_turn_sandbox_policy/1`
- Add: `claude_permission_mode/0`, `claude_dangerously_skip_permissions?/0`, `claude_max_turns/0`, `claude_output_format/0`, `claude_model/0`, `claude_allowed_tools/0`

**Step 4: Update `validate!/0`**

Remove `require_valid_codex_runtime_settings/0`. Rename `require_codex_command/0` to `require_claude_command/0`. The validation chain becomes:
```elixir
def validate! do
  with {:ok, _workflow} <- current_workflow(),
       :ok <- require_tracker_kind(),
       :ok <- require_linear_token(),
       :ok <- require_linear_project() do
    require_claude_command()
  end
end
```

**Step 5: Update `extract_codex_options/1` -> `extract_claude_options/1`**

```elixir
defp extract_claude_options(section) do
  %{}
  |> put_if_present(:command, command_value(Map.get(section, "command")))
  |> put_if_present(:permission_mode, scalar_string_value(Map.get(section, "permission_mode")))
  |> put_if_present(:dangerously_skip_permissions, boolean_value(Map.get(section, "dangerously_skip_permissions")))
  |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
  |> put_if_present(:output_format, scalar_string_value(Map.get(section, "output_format")))
  |> put_if_present(:model, scalar_string_value(Map.get(section, "model")))
  |> put_if_present(:allowed_tools, tools_list_value(Map.get(section, "allowed_tools")))
  |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
  |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
end
```

Add `tools_list_value/1`:
```elixir
defp tools_list_value(values) when is_list(values) do
  filtered = Enum.filter(values, &is_binary/1) |> Enum.reject(&(String.trim(&1) == ""))
  if filtered == [], do: :omit, else: filtered
end
defp tools_list_value(_value), do: :omit
```

Update `extract_workflow_options/1` to call `extract_claude_options` instead of `extract_codex_options`, reading from `section_map(config, "claude")`.

**Step 6: Update test_support.exs**

Replace all `codex_*` keys in `workflow_content/1` defaults and YAML generation with `claude_*` equivalents:
- `codex_command: "codex app-server"` -> `claude_command: "claude"`
- `codex_approval_policy: ...` -> delete
- `codex_thread_sandbox: ...` -> delete
- `codex_turn_sandbox_policy: ...` -> delete
- `codex_turn_timeout_ms: ...` -> `claude_turn_timeout_ms: 3_600_000`
- `codex_read_timeout_ms: ...` -> delete
- `codex_stall_timeout_ms: ...` -> `claude_stall_timeout_ms: 300_000`
- Add: `claude_permission_mode: "bypassPermissions"`, `claude_dangerously_skip_permissions: true`, `claude_max_turns: 50`, `claude_output_format: "stream-json"`, `claude_model: nil`, `claude_allowed_tools: nil`

Update YAML generation to emit `claude:` section instead of `codex:`.

**Step 7: Update core_test.exs config tests**

Update test assertions:
- `codex_command: ""` -> `claude_command: ""`
- `codex_command: "/bin/sh app-server"` -> `claude_command: "/usr/bin/claude"`
- Remove tests for `codex_approval_policy`, `codex_thread_sandbox`, `codex_turn_sandbox_policy` validation
- Update error atoms: `:missing_codex_command` -> `:missing_claude_command`
- Update `Config.validate!()` assertions

**Step 8: Run tests to verify config changes**

Run: `pushd /home/vic/Work/symphony/elixir && mix test test/symphony_elixir/core_test.exs --trace && popd`
Expected: All config-related tests pass.

**Step 9: Commit**

```
git add elixir/lib/symphony_elixir/config.ex elixir/test/support/test_support.exs elixir/test/symphony_elixir/core_test.exs
git commit -m "Replace codex config schema with claude config fields"
```

---

### Task 2: Claude CLI subprocess module

**Files:**
- Create: `elixir/lib/symphony_elixir/claude/cli.ex`
- Create: `elixir/lib/symphony_elixir/claude/stream_parser.ex`
- Delete: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Delete: `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`

**Step 1: Create `claude/stream_parser.ex`**

This module handles newline-delimited JSON parsing from Claude Code's stdout.

```elixir
defmodule SymphonyElixir.Claude.StreamParser do
  @moduledoc """
  Parses newline-delimited JSON events from Claude Code's stream-json output.
  """

  require Logger

  @doc """
  Parse a single JSON line from stdout. Returns {:ok, event_map} or {:error, reason}.
  """
  @spec parse_line(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = payload} -> {:ok, normalize_event(payload)}
      {:ok, _other} -> {:error, {:not_a_map, line}}
      {:error, reason} -> {:error, {:json_parse_error, reason, line}}
    end
  end

  @doc """
  Extract session_id from a parsed event, if present.
  """
  @spec extract_session_id(map()) :: String.t() | nil
  def extract_session_id(%{"session_id" => id}) when is_binary(id), do: id
  def extract_session_id(%{session_id: id}) when is_binary(id), do: id
  def extract_session_id(_event), do: nil

  @doc """
  Extract usage data from a parsed event.
  Returns a map with :input_tokens, :output_tokens, :total_tokens or nil.
  """
  @spec extract_usage(map()) :: map() | nil
  def extract_usage(event) do
    usage = Map.get(event, "usage") || Map.get(event, :usage)
    normalize_usage(usage)
  end

  defp normalize_usage(%{} = usage) do
    input = integer_field(usage, ["input_tokens", :input_tokens])
    output = integer_field(usage, ["output_tokens", :output_tokens])
    total = integer_field(usage, ["total_tokens", :total_tokens])

    if input || output || total do
      %{
        input_tokens: input || 0,
        output_tokens: output || 0,
        total_tokens: total || (input || 0) + (output || 0)
      }
    end
  end

  defp normalize_usage(_), do: nil

  defp normalize_event(payload) do
    type = Map.get(payload, "type") || Map.get(payload, :type)
    Map.put(payload, :event_type, categorize_type(type))
  end

  defp categorize_type("assistant"), do: :assistant
  defp categorize_type("tool"), do: :tool_use
  defp categorize_type("result"), do: :result
  defp categorize_type("system"), do: :system
  defp categorize_type(_), do: :unknown

  defp integer_field(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        v when is_integer(v) and v >= 0 -> v
        _ -> nil
      end
    end)
  end
end
```

**Step 2: Create `claude/cli.ex`**

This module spawns `claude -p` subprocesses via Erlang ports.

```elixir
defmodule SymphonyElixir.Claude.CLI do
  @moduledoc """
  Spawns Claude Code CLI subprocesses and streams events back to the caller.
  """

  require Logger
  alias SymphonyElixir.{Claude.StreamParser, Config}

  @port_line_bytes 10_485_760
  @max_log_bytes 1_000

  @type run_result :: %{
          session_id: String.t() | nil,
          exit_code: integer(),
          usage: map() | nil
        }

  @doc """
  Run a first-turn Claude Code session with the given prompt.
  """
  @spec run(String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(prompt, workspace, opts \\ []) do
    args = build_first_turn_args(prompt, workspace)
    execute(args, workspace, opts)
  end

  @doc """
  Resume an existing Claude Code session with continuation guidance.
  """
  @spec resume(String.t(), String.t(), Path.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def resume(session_id, prompt, workspace, opts \\ []) do
    args = build_resume_args(session_id, prompt, workspace)
    execute(args, workspace, opts)
  end

  defp execute(args, workspace, opts) do
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, Config.claude_turn_timeout_ms())

    with :ok <- validate_workspace(workspace) do
      command = Config.claude_command()
      {cmd, cmd_args} = parse_command(command, args)

      port = Port.open(
        {:spawn_executable, cmd},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, @port_line_bytes},
          {:cd, Path.expand(workspace)},
          {:args, cmd_args}
        ]
      )

      deadline = System.monotonic_time(:millisecond) + turn_timeout_ms

      try do
        stream_loop(port, deadline, on_event, %{
          session_id: nil,
          usage: nil,
          buffer: ""
        })
      catch
        :exit, reason ->
          safe_port_close(port)
          {:error, {:subprocess_exit, reason}}
      end
    end
  end

  defp stream_loop(port, deadline, on_event, state) do
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining_ms <= 0 do
      safe_port_close(port)
      {:error, :turn_timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          state = handle_line(line, on_event, state)
          stream_loop(port, deadline, on_event, state)

        {^port, {:data, {:noeol, chunk}}} ->
          stream_loop(port, deadline, on_event, %{state | buffer: state.buffer <> chunk})

        {^port, {:exit_status, 0}} ->
          {:ok, %{
            session_id: state.session_id,
            exit_code: 0,
            usage: state.usage
          }}

        {^port, {:exit_status, code}} ->
          {:error, {:subprocess_exit, code}}
      after
        remaining_ms ->
          safe_port_close(port)
          {:error, :turn_timeout}
      end
    end
  end

  defp handle_line(line, on_event, state) do
    full_line = state.buffer <> line
    state = %{state | buffer: ""}

    case StreamParser.parse_line(full_line) do
      {:ok, event} ->
        session_id = StreamParser.extract_session_id(event) || state.session_id
        usage = StreamParser.extract_usage(event) || state.usage
        on_event.(event)
        %{state | session_id: session_id, usage: usage}

      {:error, reason} ->
        Logger.debug("Unparseable stream line: #{inspect(reason)} line=#{String.slice(full_line, 0, @max_log_bytes)}")
        state
    end
  end

  defp build_first_turn_args(prompt, workspace) do
    base = [
      "-p", prompt,
      "--output-format", Config.claude_output_format(),
      "--max-turns", to_string(Config.claude_max_turns()),
      "--permission-mode", Config.claude_permission_mode(),
      "--cwd", Path.expand(workspace)
    ]

    base
    |> maybe_add_flag(Config.claude_dangerously_skip_permissions?(), "--dangerously-skip-permissions")
    |> maybe_add_option(Config.claude_model(), "--model")
    |> maybe_add_allowed_tools(Config.claude_allowed_tools())
  end

  defp build_resume_args(session_id, prompt, workspace) do
    [
      "--resume", session_id,
      "-p", prompt,
      "--output-format", Config.claude_output_format(),
      "--max-turns", to_string(Config.claude_max_turns()),
      "--cwd", Path.expand(workspace)
    ]
  end

  defp maybe_add_flag(args, true, flag), do: args ++ [flag]
  defp maybe_add_flag(args, _, _flag), do: args

  defp maybe_add_option(args, nil, _opt), do: args
  defp maybe_add_option(args, value, opt), do: args ++ [opt, value]

  defp maybe_add_allowed_tools(args, nil), do: args
  defp maybe_add_allowed_tools(args, []), do: args
  defp maybe_add_allowed_tools(args, tools) when is_list(tools) do
    Enum.reduce(tools, args, fn tool, acc -> acc ++ ["--allowedTools", tool] end)
  end

  defp parse_command(command, extra_args) do
    parts = String.split(command, ~r/\s+/, trim: true)
    {cmd, cmd_args} = case parts do
      [cmd | rest] -> {cmd, rest ++ extra_args}
      [] -> {"claude", extra_args}
    end

    resolved_cmd = System.find_executable(cmd) || cmd
    {resolved_cmd, cmd_args}
  end

  defp validate_workspace(workspace) do
    expanded = Path.expand(workspace)
    root = Path.expand(Config.workspace_root())

    cond do
      !File.dir?(expanded) -> {:error, {:invalid_workspace_cwd, :not_a_directory}}
      !String.starts_with?(expanded, root) -> {:error, {:invalid_workspace_cwd, :outside_root}}
      true -> :ok
    end
  end

  defp safe_port_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    catch
      :error, :badarg -> :ok
    end
  end
end
```

**Step 3: Delete Codex modules**

Remove `elixir/lib/symphony_elixir/codex/app_server.ex` and `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`.

**Step 4: Run compilation check**

Run: `pushd /home/vic/Work/symphony/elixir && mix compile --warnings-as-errors 2>&1 | head -50 && popd`
Expected: Compilation errors from modules still referencing Codex (agent_runner, orchestrator, tests). This is expected -- we fix those in subsequent tasks.

**Step 5: Commit**

```
git add elixir/lib/symphony_elixir/claude/ && git rm elixir/lib/symphony_elixir/codex/app_server.ex elixir/lib/symphony_elixir/codex/dynamic_tool.ex
git commit -m "Add claude/cli.ex and stream_parser.ex, remove codex modules"
```

---

### Task 3: Agent runner -- replace Codex calls with Claude CLI

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`

**Step 1: Update aliases and imports**

Replace:
```elixir
alias SymphonyElixir.Codex.AppServer
```
With:
```elixir
alias SymphonyElixir.Claude.CLI, as: ClaudeCLI
```

**Step 2: Rewrite `run_codex_turns/4` -> `run_claude_turns/4`**

The multi-turn loop no longer needs a persistent session. Each turn is a standalone subprocess. Track `session_id` across turns for `--resume`.

```elixir
defp run_claude_turns(workspace, issue, claude_update_recipient, opts) do
  max_turns = Keyword.get(opts, :max_turns, Config.agent_max_turns())
  issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

  do_run_claude_turns(workspace, issue, claude_update_recipient, opts, issue_state_fetcher, 1, max_turns, nil)
end

defp do_run_claude_turns(workspace, issue, claude_update_recipient, opts, issue_state_fetcher, turn_number, max_turns, session_id) do
  prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

  cli_opts = [
    on_event: claude_event_handler(claude_update_recipient, issue)
  ]

  result =
    if session_id == nil do
      ClaudeCLI.run(prompt, workspace, cli_opts)
    else
      ClaudeCLI.resume(session_id, prompt, workspace, cli_opts)
    end

  case result do
    {:ok, %{session_id: new_session_id}} ->
      effective_session_id = new_session_id || session_id
      Logger.info("Completed agent turn for #{issue_context(issue)} session_id=#{effective_session_id} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{max_turns}")

          do_run_claude_turns(
            workspace,
            refreshed_issue,
            claude_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns,
            effective_session_id
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active")
          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end

    {:error, reason} ->
      {:error, reason}
  end
end
```

**Step 3: Update event handler**

Replace `codex_message_handler/2` with `claude_event_handler/2`:
```elixir
defp claude_event_handler(recipient, issue) do
  fn event ->
    send_claude_update(recipient, issue, event)
  end
end

defp send_claude_update(recipient, %Issue{id: issue_id}, event)
     when is_binary(issue_id) and is_pid(recipient) do
  timestamp = DateTime.utc_now()
  session_id = SymphonyElixir.Claude.StreamParser.extract_session_id(event)
  usage = SymphonyElixir.Claude.StreamParser.extract_usage(event)
  event_type = Map.get(event, :event_type, :unknown)

  send(recipient, {:claude_worker_update, issue_id, %{
    event: event_type,
    timestamp: timestamp,
    session_id: session_id,
    usage: usage,
    raw: event
  }})
  :ok
end

defp send_claude_update(_recipient, _issue, _event), do: :ok
```

**Step 4: Update `run/3` to call `run_claude_turns` instead of `run_codex_turns`**

**Step 5: Update continuation prompt**

The existing `build_turn_prompt/4` references "Codex turn" -- update to "Claude turn" or just "agent turn":
```elixir
defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
  """
  Continuation guidance:

  - The previous turn completed normally, but the Linear issue is still in an active state.
  - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
  - Resume from the current workspace state instead of restarting from scratch.
  - The original task instructions and prior turn context are already present in this session, so do not restate them before acting.
  - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
  """
end
```

**Step 6: Commit**

```
git add elixir/lib/symphony_elixir/agent_runner.ex
git commit -m "Rewrite agent runner to use Claude CLI subprocess model"
```

---

### Task 4: Orchestrator field renames

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`

**Step 1: Rename State struct fields**

In `defmodule State`, rename:
- `codex_totals` -> `claude_totals`
- `codex_rate_limits` -> `claude_rate_limits`

**Step 2: Rename running entry fields**

In `do_dispatch_issue/3`, rename the running entry map keys:
- `codex_app_server_pid` -> `claude_pid`
- `codex_input_tokens` -> `claude_input_tokens`
- `codex_output_tokens` -> `claude_output_tokens`
- `codex_total_tokens` -> `claude_total_tokens`
- `codex_last_reported_input_tokens` -> `claude_last_reported_input_tokens`
- `codex_last_reported_output_tokens` -> `claude_last_reported_output_tokens`
- `codex_last_reported_total_tokens` -> `claude_last_reported_total_tokens`
- `last_codex_message` -> `last_claude_message`
- `last_codex_timestamp` -> `last_claude_timestamp`
- `last_codex_event` -> `last_claude_event`

**Step 3: Rename message pattern**

Update `handle_info` clauses:
- `{:codex_worker_update, issue_id, update}` -> `{:claude_worker_update, issue_id, update}`

**Step 4: Rename private functions**

- `integrate_codex_update/2` -> `integrate_claude_update/2`
- `summarize_codex_update/1` -> `summarize_claude_update/1`
- `apply_codex_token_delta/2` -> `apply_claude_token_delta/2`
- `apply_codex_rate_limits/2` -> `apply_claude_rate_limits/2`
- `codex_app_server_pid_for_update/2` -> delete (no app-server PID in Claude Code model; `claude_pid` can come from the port info or be nil)
- `session_id_for_update/2` -- keep, works the same
- `last_activity_timestamp/1` -- update field access from `:last_codex_timestamp` to `:last_claude_timestamp`

**Step 5: Simplify usage extraction**

Claude Code's stream-json events have flatter usage data. Replace the deeply nested path resolution in `extract_token_usage/1` with direct access:

```elixir
defp extract_token_usage(update) do
  usage = Map.get(update, :usage) || Map.get(update, "usage") || %{}

  if is_map(usage) do
    usage
  else
    %{}
  end
end
```

The `absolute_token_usage_from_payload/1` and `turn_completed_usage_from_payload/1` functions with their Codex-specific nested JSON-RPC paths can be deleted.

**Step 6: Update snapshot fields**

In `handle_call(:snapshot, ...)`, rename all `codex_*` fields in the response map to `claude_*`.

**Step 7: Update empty totals constant**

`@empty_codex_totals` -> `@empty_claude_totals`

**Step 8: Run compilation**

Run: `pushd /home/vic/Work/symphony/elixir && mix compile --warnings-as-errors 2>&1 | head -50 && popd`
Expected: Compiles clean (or errors from tests only).

**Step 9: Commit**

```
git add elixir/lib/symphony_elixir/orchestrator.ex
git commit -m "Rename codex_* fields to claude_* throughout orchestrator"
```

---

### Task 5: Update remaining modules and aliases

**Files:**
- Modify: `elixir/lib/symphony_elixir.ex`
- Modify: `elixir/lib/symphony_elixir/cli.ex`
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify: `elixir/lib/symphony_elixir/log_file.ex`
- Modify: `elixir/lib/symphony_elixir/specs_check.ex`
- Modify: `elixir/test/support/test_support.exs` (alias updates)

**Step 1: Update test_support.exs alias**

Replace:
```elixir
alias SymphonyElixir.Codex.AppServer
```
With:
```elixir
alias SymphonyElixir.Claude.CLI, as: ClaudeCLI
```

**Step 2: Update cli.ex default command**

If the CLI module references a default command string, update from `codex app-server` to `claude`.

**Step 3: Update status_dashboard.ex labels**

Search for any display strings referencing "Codex" and update to "Claude":
- "Codex session" -> "Claude session"
- Any `codex_*` field accesses in snapshot rendering -> `claude_*`

**Step 4: Update log_file.ex**

Update any path references or field names that use `codex`.

**Step 5: Update specs_check.ex**

If it references Codex modules for spec validation, update.

**Step 6: Compile and verify**

Run: `pushd /home/vic/Work/symphony/elixir && mix compile --warnings-as-errors && popd`
Expected: Clean compilation, no warnings.

**Step 7: Commit**

```
git add -A elixir/lib/
git commit -m "Update remaining modules: aliases, labels, default command"
```

---

### Task 6: Update all tests

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/app_server_test.exs` (rename or rewrite)
- Modify: `elixir/test/symphony_elixir/dynamic_tool_test.exs` (delete)
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Modify: `elixir/test/symphony_elixir/cli_test.exs`
- Modify: `elixir/test/symphony_elixir/status_dashboard_snapshot_test.exs`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- Modify: `elixir/test/fixtures/status_dashboard_snapshots/*.snapshot.txt`

**Step 1: Delete dynamic_tool_test.exs**

No equivalent needed.

**Step 2: Rewrite app_server_test.exs -> claude_cli_test.exs**

The existing tests use fake shell scripts that speak JSON-RPC (stdin/stdout line protocol). Replace with fake scripts that behave like Claude Code:
- Emit newline-delimited JSON to stdout (no stdin reading needed)
- Include `session_id` in events
- Exit with code 0 for success, non-zero for failure

The fake-claude script pattern:
```bash
#!/bin/sh
# Emit stream-json events to stdout
echo '{"type":"system","session_id":"test-session-1"}'
echo '{"type":"assistant","message":"Working on it"}'
echo '{"type":"result","session_id":"test-session-1","usage":{"input_tokens":100,"output_tokens":50}}'
exit 0
```

Key tests to write:
- First turn uses correct CLI flags (`-p`, `--output-format`, `--max-turns`, `--permission-mode`, `--dangerously-skip-permissions`, `--cwd`)
- `--model` only included when configured
- `--allowedTools` only included when configured
- `--resume <session_id>` used for continuation turns
- Exit code 0 is success, non-zero is failure
- Session ID extracted from output
- Workspace cwd is correct

**Step 3: Update core_test.exs agent runner tests**

The agent runner tests that use fake-codex scripts need rewriting. Replace the JSON-RPC stdin/stdout protocol with Claude Code's simpler model:
- Remove the `count`-based stdin reading loop
- Have the script just emit JSON to stdout and exit
- Update assertions from `{:codex_worker_update, ...}` to `{:claude_worker_update, ...}`
- Update trace file assertions from checking `thread/start` and `turn/start` JSON-RPC methods to checking CLI arguments

**Step 4: Update orchestrator tests**

- Rename `codex_totals` -> `claude_totals` in State construction
- Rename all `codex_*` fields in running entry maps
- Update message patterns from `:codex_worker_update` to `:claude_worker_update`

**Step 5: Update snapshot tests**

- Update snapshot fixture files to use `claude_*` field names
- Update assertions in snapshot tests

**Step 6: Run full test suite**

Run: `pushd /home/vic/Work/symphony/elixir && mix test --trace && popd`
Expected: All tests pass.

**Step 7: Commit**

```
git add -A elixir/test/
git commit -m "Update all tests for Claude Code subprocess model"
```

---

### Task 7: Update WORKFLOW.md

**Files:**
- Modify: `elixir/WORKFLOW.md`

**Step 1: Replace `codex:` front matter with `claude:`**

Replace:
```yaml
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
```

With:
```yaml
claude:
  command: claude
  permission_mode: bypassPermissions
  dangerously_skip_permissions: true
  max_turns: 50
  output_format: stream-json
```

**Step 2: Update prompt body references**

Search for "Codex" in the prompt body and update to "Claude" or remove as appropriate. The prompt template references `.codex/skills/land/SKILL.md` -- that's a repo path, not a Symphony config, so leave it unless the target repo changes.

**Step 3: Commit**

```
git add elixir/WORKFLOW.md
git commit -m "Update WORKFLOW.md front matter from codex to claude config"
```

---

### Task 8: Run full validation

**Step 1: Compile with warnings-as-errors**

Run: `pushd /home/vic/Work/symphony/elixir && mix compile --warnings-as-errors && popd`
Expected: Clean.

**Step 2: Run full test suite**

Run: `pushd /home/vic/Work/symphony/elixir && mix test --trace && popd`
Expected: All pass.

**Step 3: Run linting**

Run: `pushd /home/vic/Work/symphony/elixir && mix credo --strict && popd`
Expected: Clean or only minor warnings.

**Step 4: Verify no remaining codex references in source**

Run: `grep -ri "codex" elixir/lib/ elixir/test/ --include="*.ex" --include="*.exs" | grep -v ".codex/skills"` from the repo root.
Expected: No matches (except repo paths like `.codex/skills` which are target-repo references in the WORKFLOW.md prompt).

**Step 5: Commit any final fixes**

---

### Task 9: Update mix.exs coverage ignore list

**Files:**
- Modify: `elixir/mix.exs`

**Step 1: Update ignored modules**

Replace:
```elixir
SymphonyElixir.Codex.AppServer,
SymphonyElixir.Codex.DynamicTool,
```

With:
```elixir
SymphonyElixir.Claude.CLI,
SymphonyElixir.Claude.StreamParser,
```

**Step 2: Commit**

```
git add elixir/mix.exs
git commit -m "Update mix.exs coverage ignore list for claude modules"
```
