# Gleam rewrite design

> Obsolete: the Gleam implementation was removed. Rondo development continues in `elixir/`.

Status: Superseded
Date: 2026-03-08

## Context

Rondo is currently ~7,500 LOC Elixir with ~6,500 LOC tests. It's a daemon that polls Linear for issues, creates isolated git worktree workspaces, and runs Claude Code sessions as subprocesses. The Elixir version works but we want the type safety and developer experience of Gleam.

This is a full rewrite, not a port. The language-agnostic SPEC.md drives the design. The Elixir version stays around as a behavioral reference but gets no new work.

## Project structure

```
gleam/
├── gleam.toml
├── src/
│   ├── rondo.gleam              # Entry point, top-level supervisor
│   ├── rondo/
│   │   ├── config.gleam         # Typed config from env + WORKFLOW.md
│   │   ├── cli.gleam            # CLI arg parsing
│   │   ├── orchestrator.gleam   # Poll tracker, dispatch work, manage concurrency
│   │   ├── tracker.gleam        # Tracker type + dispatch (Linear or Memory)
│   │   ├── tracker/
│   │   │   ├── linear.gleam     # Linear GraphQL client
│   │   │   └── memory.gleam     # In-memory tracker for testing
│   │   ├── workspace.gleam      # Git worktree creation/cleanup
│   │   ├── agent.gleam          # Agent runner actor (one Claude session)
│   │   ├── claude/
│   │   │   ├── cli.gleam        # Port/subprocess management via FFI
│   │   │   └── stream.gleam     # Stream-JSON parser, typed event ADT
│   │   ├── prompt.gleam         # Prompt builder from WORKFLOW.md templates
│   │   ├── workflow.gleam       # WORKFLOW.md parser + typed config
│   │   ├── dashboard.gleam      # Terminal dashboard (ANSI rendering)
│   │   ├── http.gleam           # Health/status endpoint
│   │   └── log.gleam            # Per-agent log file management
│   └── rondo/ffi/
│       └── port.gleam           # Erlang port FFI bindings
├── test/
└── workflow.md
```

## Concurrency model

Typed actors via `gleam_otp/actor`. Each actor gets its own message custom type -- no catch-all handlers, unhandled messages are compile errors.

| Actor | Role | Messages |
|-------|------|----------|
| Orchestrator | Polls tracker, spawns/monitors agents, enforces max concurrency | `StartRun`, `RunFinished`, `Tick` |
| Agent | Manages one Claude CLI session for one issue | `Begin`, `StreamEvent`, `Stop` |
| Dashboard | Receives state updates, redraws terminal | `AgentUpdate`, `Redraw` |
| WorkflowStore | Caches parsed WORKFLOW.md per repo | `Get`, `Invalidate` |

Supervision tree:

```
Application
└── Supervisor
    ├── Orchestrator (permanent)
    ├── Dashboard (permanent)
    ├── WorkflowStore (permanent)
    └── AgentSupervisor (dynamic)
        ├── Agent<issue-1>
        ├── Agent<issue-2>
        └── ...
```

## Core types

The main payoff of the rewrite. The Elixir version uses maps and atoms loosely; Gleam makes these explicit at compile time.

```gleam
pub type Issue {
  Issue(
    id: String,
    title: String,
    description: String,
    labels: List(String),
    state: IssueState,
  )
}

pub type IssueState {
  Todo
  InProgress
  InReview
  Done
  Cancelled
}

pub type ClaudeEvent {
  SystemEvent(message: String, session_id: String)
  AssistantMessage(content: String, token_usage: TokenUsage)
  ToolUse(name: String, input: String)
  ToolResult(output: String, is_error: Bool)
  ResultEvent(result: String, session_id: String, token_usage: TokenUsage)
  RateLimitEvent(retry_after: Int)
}

pub type TokenUsage {
  TokenUsage(input: Int, output: Int, cache_read: Int, cache_write: Int)
}

pub type RunResult {
  Completed(session_id: String, summary: String)
  Failed(reason: RunFailure)
  TimedOut(session_id: String, elapsed_ms: Int)
}

pub type RunFailure {
  ProcessCrashed(exit_code: Int)
  ParseError(raw: String)
  RateLimited(retry_after: Int)
  WorkspaceError(detail: String)
}

pub type WorkflowConfig {
  WorkflowConfig(
    prompt_template: String,
    allowed_tools: List(String),
    max_turns: Int,
    timeout_ms: Int,
    hooks: List(Hook),
  )
}
```

What this gets us:
- Stream parser can't produce garbage. Every `ClaudeEvent` variant is exhaustively matched.
- Run results are explicit. `RunFailure` enumerates what actually goes wrong.
- Config is validated at parse time. No runtime `KeyError` from missing fields.

## Dependencies

| Need | Package |
|------|---------|
| OTP actors/supervisors | `gleam_otp` |
| Process/port primitives | `gleam_erlang` |
| HTTP client (Linear API) | `gleam_httpc` |
| HTTP server (health endpoint) | `mist` |
| JSON parsing | `gleam_json` |
| Environment variables | `envoy` |
| Standard library | `gleam_stdlib` |
| CLI arg parsing | `argv` + `glint` |
| File I/O | `simplifile` |
| Terminal ANSI | `gleam_community_ansi` or custom |

## FFI boundaries

Three small Erlang modules:

1. **Port with PTY** (`rondo_port_ffi.erl`, ~50 lines) -- wraps `open_port` with PTY options for unbuffered Claude CLI output.
2. **System time** -- if `gleam_otp` doesn't cover monotonic clocks.
3. **Signal handling** -- SIGTERM/SIGINT trapping for graceful shutdown and orphan cleanup.

## Build order

Bottom-up by dependency:

1. Types + config -- pure functions, testable immediately
2. Stream parser -- pure `String -> List(ClaudeEvent)`, most fiddly module, benefits most from types
3. Tracker -- Linear GraphQL client + memory tracker
4. Workspace -- git worktree management
5. Port FFI + Agent -- Erlang FFI module, then the Agent actor
6. Orchestrator -- main loop, depends on tracker + workspace + agent
7. Dashboard -- terminal rendering, purely observational
8. CLI + HTTP -- entry point and health endpoint, wiring everything together

Each phase can be tested independently. Functional parity (minus dashboard) is reached at phase 6.
