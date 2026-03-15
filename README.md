# Rondo

Rondo turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

<p>
  <img width="1906" height="1047" alt="Rondo dashboard - light mode" src="https://github.com/user-attachments/assets/5bb16a0a-91ac-4080-949b-5bcf7fc280c0" />
</p>
<p>
  <img width="1906" height="1047" alt="Rondo dashboard - dark mode" src="https://github.com/user-attachments/assets/c0ab2d80-1f90-43f6-ba1f-7a6c3165186d" />
</p>


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

## Releases

### v0.1.0

First release. Phoenix LiveView dashboard with real-time agent observability, Chart.js visualizations, dark mode, archived run persistence, and event stream categorization. See the [full release notes](https://github.com/sandsower/rondo/releases/tag/v0.1.0).

## License

This project is licensed under the [Apache License 2.0](LICENSE).
