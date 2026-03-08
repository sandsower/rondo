# Rondo

Rondo turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

<img width="1920" height="1200" alt="2026-03-08-19:11:44-screenshot" src="https://github.com/user-attachments/assets/fdcfc501-f625-4921-b639-d4db806dda5f" />

> [!NOTE]
> This is a fork of [openai/symphony](https://github.com/openai/symphony). The original project
> used OpenAI's Codex as its agent backend. This fork replaces Codex with
> [Claude Code](https://docs.anthropic.com/en/docs/claude-code) as a CLI subprocess, along with
> substantial changes to the stream parser, process supervision, and dashboard. The spec
> (`SPEC.md`) and Elixir implementation have been rewritten accordingly.

> [!WARNING]
> Rondo is an engineering preview for testing in trusted environments.

## What it does

Rondo polls Linear for issues, creates an isolated workspace for each one, and launches a
Claude Code session to do the work. When the agent finishes, it moves the ticket forward
(opens a PR, requests review, etc.). Multiple agents run concurrently.

See [elixir/README.md](elixir/README.md) for setup and usage.

## What changed from upstream

- **Agent backend:** Codex app-server replaced with Claude Code CLI (`claude -p --output-format stream-json`)
- **Stream parser:** Rewritten for Claude Code's stream-json event format (system, assistant, result, rate_limit events)
- **Process model:** No JSON-RPC handshake; each agent is a subprocess managed via Erlang ports with PTY wrapping for unbuffered output
- **Continuations:** `claude --resume <session_id>` instead of Codex thread turns
- **Permissions:** `--dangerously-skip-permissions` + `--allowedTools` instead of per-request approval cycles
- **Config:** `claude.*` fields replace `codex.*` throughout WORKFLOW.md and the codebase
- **Dashboard:** Real-time token tracking, phase display (hooks/claude), orphan process cleanup on shutdown

## License

This project is licensed under the [Apache License 2.0](LICENSE).
