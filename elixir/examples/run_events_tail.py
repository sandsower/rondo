#!/usr/bin/env python3
"""Minimal external consumer of the rondo.core/v1 run event feed.

This script tails a rondo run from start to finish using ONLY the execution
contract's `run.events` concepts: `service_id`, `repo_id`, `run_id`, and the
opaque `event_cursor`. It never reads the run ledger, workspace, or artifact
layout directly - the only rondo-specific thing it knows is how to invoke the
feed transport (the `mix rondo.run_events` CLI), which returns:

    {"events": [ ...contract events... ], "next_event_cursor": "<opaque>"}

Cursor replay: it starts from an empty cursor (replay from the beginning),
prints each new event, advances the cursor to `next_event_cursor`, and re-polls.
An archived (completed) run drains in a single poll; an active run is tailed
until a terminal `rondo.run.status_changed` (completed/failed/terminated) is
seen. Because the cursor is opaque and the feed is append-only, re-polling never
relaunches completed work.

Usage:
    examples/run_events_tail.py --repo-id REPO --run-id RUN \
        [--service-id ID] [--workspace-root PATH] [--interval SECONDS]

The feed command defaults to `mix rondo.run_events` (run from the elixir/ dir);
override with the RONDO_FEED_CMD env var, e.g.:
    RONDO_FEED_CMD="mise exec -- mix rondo.run_events"
"""

import argparse
import json
import os
import shlex
import subprocess
import sys
import time

TERMINAL_STATUSES = {"completed", "failed", "terminated"}


def poll(feed_cmd, repo_id, run_id, service_id, workspace_root, cursor):
    """Call the run.events transport and return its parsed contract response."""
    cmd = list(feed_cmd)
    cmd += ["--repo-id", repo_id, "--run-id", run_id, "--cursor", cursor]
    if service_id:
        cmd += ["--service-id", service_id]
    if workspace_root:
        cmd += ["--workspace-root", workspace_root]

    completed = subprocess.run(cmd, capture_output=True, text=True)
    if completed.returncode != 0:
        sys.stderr.write(completed.stderr)
        raise SystemExit(f"feed transport failed (exit {completed.returncode})")

    # The transport prints one JSON object as its last stdout line.
    last_line = [line for line in completed.stdout.splitlines() if line.strip()][-1]
    return json.loads(last_line)


def render(event):
    kind = event.get("type")
    seq = event.get("sequence")
    ts = event.get("timestamp")
    if kind == "rondo.run.evidence_recorded":
        detail = f'{event.get("artifact_kind")} -> {event.get("uri")}'
    else:
        detail = f'status={event.get("status")}'
    print(f"[{seq:>3}] {ts}  {kind}  {detail}")


def main():
    parser = argparse.ArgumentParser(description="Tail a rondo.core/v1 run event feed.")
    parser.add_argument("--repo-id", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--service-id", default=None)
    parser.add_argument("--workspace-root", default=None)
    parser.add_argument("--interval", type=float, default=2.0, help="poll interval for active runs (seconds)")
    args = parser.parse_args()

    feed_cmd = shlex.split(os.environ.get("RONDO_FEED_CMD", "mix rondo.run_events"))

    cursor = ""  # empty cursor = replay from the beginning
    seen_terminal = False

    while not seen_terminal:
        response = poll(feed_cmd, args.repo_id, args.run_id, args.service_id, args.workspace_root, cursor)
        events = response.get("events", [])

        for event in events:
            render(event)
            if event.get("type") == "rondo.run.status_changed" and event.get("status") in TERMINAL_STATUSES:
                seen_terminal = True

        next_cursor = response.get("next_event_cursor", cursor)

        if seen_terminal:
            break

        if next_cursor == cursor:
            # No progress: an active run with no new events yet. Wait and re-poll.
            time.sleep(args.interval)
        cursor = next_cursor

    print("run reached a terminal status; feed drained.")


if __name__ == "__main__":
    main()
