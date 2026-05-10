defmodule Rondo.RunLedgerTest do
  use Rondo.TestSupport

  alias Rondo.RunLedger

  @now ~U[2026-05-10 15:30:12Z]

  test "create_run writes a stable manifest and incremental checkpoint index" do
    workspace_root = tmp_dir("ledger-create")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "a1b2c3d4"
             )

    assert ledger.run_id == "MT-401-20260510T153012Z-a1b2c3d4"
    assert ledger.next_seq == 1
    assert File.exists?(ledger.manifest_path)

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["schema_version"] == 1
    assert manifest["run_id"] == ledger.run_id
    assert manifest["status"] == "running"
    assert manifest["issue"]["identifier"] == "MT-401"
    assert manifest["issue"]["title"] == "Durable ledger"
    assert manifest["repo"]["workspace_root"] == Path.expand(workspace_root)
    assert manifest["checkpoints"] == []

    assert {:ok, ledger} =
             RunLedger.write_checkpoint(ledger, :dispatch, %{attempt: 1}, timestamp: @now)

    checkpoint_path = Path.join(ledger.run_dir, "checkpoints/0001-dispatch.json")
    assert File.exists?(checkpoint_path)

    checkpoint = decode_json!(checkpoint_path)
    assert checkpoint["seq"] == 1
    assert checkpoint["kind"] == "dispatch"
    assert checkpoint["payload"] == %{"attempt" => 1}

    manifest = decode_json!(ledger.manifest_path)
    assert [%{"seq" => 1, "kind" => "dispatch", "path" => "checkpoints/0001-dispatch.json"}] = manifest["checkpoints"]
    assert ledger.next_seq == 2
  end

  test "create_run accepts string-keyed issue maps" do
    workspace_root = tmp_dir("ledger-string-map")

    issue = %{
      "id" => "issue-string",
      "identifier" => "MT-STRING",
      "title" => "String issue",
      "description" => "Loaded from JSON",
      "state" => "In Progress",
      "url" => "https://example.org/issues/MT-STRING",
      "labels" => ["json"],
      "priority" => 2
    }

    assert {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root, now: @now, random_suffix: "12345678")
    assert ledger.run_id == "MT-STRING-20260510T153012Z-12345678"

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["issue"]["id"] == "issue-string"
    assert manifest["issue"]["identifier"] == "MT-STRING"
    assert manifest["issue"]["title"] == "String issue"
    assert manifest["issue"]["description"] == "Loaded from JSON"
    assert manifest["issue"]["state"] == "In Progress"
    assert manifest["issue"]["url"] == "https://example.org/issues/MT-STRING"
    assert manifest["issue"]["labels"] == ["json"]
    assert manifest["issue"]["priority"] == 2
  end

  test "create_run generates unique run IDs across attempts" do
    workspace_root = tmp_dir("ledger-unique")
    issue = issue_fixture()

    assert {:ok, first} = RunLedger.create_run(issue, workspace_root: workspace_root)
    assert {:ok, second} = RunLedger.create_run(issue, workspace_root: workspace_root)

    assert first.run_id != second.run_id
    assert File.dir?(first.run_dir)
    assert File.dir?(second.run_dir)
    assert {:ok, _ledger} = RunLedger.write_checkpoint(first, :default_opts, %{})
  end

  test "load_manifest returns safe errors for missing or corrupted files" do
    root = tmp_dir("ledger-load")

    assert {:error, :missing} = RunLedger.load_manifest(Path.join(root, "missing/manifest.json"))

    invalid_json_path = Path.join(root, "invalid/manifest.json")
    File.mkdir_p!(Path.dirname(invalid_json_path))
    File.write!(invalid_json_path, "not json")
    assert {:error, :invalid_json} = RunLedger.load_manifest(invalid_json_path)

    invalid_manifest_path = Path.join(root, "malformed/manifest.json")
    File.mkdir_p!(Path.dirname(invalid_manifest_path))
    File.write!(invalid_manifest_path, Jason.encode!(%{"schema_version" => 1}))
    assert {:error, :invalid_manifest} = RunLedger.load_manifest(invalid_manifest_path)
  end

  test "complete_run updates terminal status and archive links" do
    workspace_root = tmp_dir("ledger-complete")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "facefeed"
             )

    assert {:ok, ledger} = RunLedger.complete_run(ledger, :terminated, %{reason: "operator"}, timestamp: @now)
    assert {:ok, ledger} = RunLedger.link_archive(ledger, nil)
    assert {:ok, ledger} = RunLedger.link_archive(ledger, "/tmp/rondo/archive.json")
    assert {:ok, ledger} = RunLedger.link_archive(ledger, "/tmp/rondo/archive.json")

    manifest = decode_json!(ledger.manifest_path)
    assert manifest["status"] == "terminated"
    assert Enum.any?(manifest["checkpoints"], &(&1["kind"] == "terminated"))
    assert Enum.count(manifest["artifacts"], &(&1["kind"] == "archive")) == 1

    assert {:ok, failed_ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "badc0de"
             )

    assert {:ok, failed_ledger} = RunLedger.complete_run(failed_ledger, :failed, %{reason: "boom"}, timestamp: @now)
    failed_manifest = decode_json!(failed_ledger.manifest_path)
    assert failed_manifest["status"] == "failed"
    assert Enum.any?(failed_manifest["checkpoints"], &(&1["kind"] == "failed"))
  end

  test "checkpoint_kind_for_agent_update maps Claude and MCP lifecycle events" do
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{"method" => "turn/started"}}) == "turn_started"
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{"method" => "turn/failed"}}) == "turn_failed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{"method" => "turn/cancelled"}}) == "turn_cancelled"
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{"method" => "turn/diff/updated"}}) == "edit_batch"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"raw" => %{"method" => "turn/completed"}}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{raw: %{method: "turn/completed"}}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "claude_starting"}) == "workspace_ready"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "session_started"}) == "turn_started"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :session_started}) == "turn_started"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :result}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{"event" => "result"}) == "turn_completed"
    assert RunLedger.checkpoint_kind_for_agent_update(%{event: :unknown}) == nil
  end

  test "load_manifest accepts either run directory or manifest path" do
    workspace_root = tmp_dir("ledger-load-dir")
    assert {:ok, ledger} = RunLedger.create_run(issue_fixture(), workspace_root: workspace_root)

    assert {:ok, by_file} = RunLedger.load_manifest(ledger.manifest_path)
    assert {:ok, by_dir} = RunLedger.load_manifest(ledger.run_dir)
    assert by_file == by_dir
  end

  test "edge-case inputs remain safe and serializable" do
    workspace_root = tmp_dir("ledger-edges")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "0ddba11"
             )

    assert {:ok, ledger} =
             RunLedger.write_checkpoint(
               ledger,
               {:custom, :kind},
               %{ok: true, at: @now, tuple: {:x}, list: [@now], long: String.duplicate("z", 5_000)},
               timestamp: "2026-05-10T15:30:12Z",
               source: %{adapter: "test", input_tokens: 1, output_tokens: 2, total_tokens: 3}
             )

    checkpoint = decode_json!(Path.join(ledger.run_dir, "checkpoints/0001-__custom___kind_.json"))
    assert checkpoint["kind"] =~ "custom"
    assert checkpoint["timestamp"] == "2026-05-10T15:30:12Z"
    assert checkpoint["payload"]["at"] == DateTime.to_iso8601(@now)
    assert checkpoint["payload"]["tuple"] =~ "x"
    assert checkpoint["payload"]["list"] == [DateTime.to_iso8601(@now)]
    assert checkpoint["payload"]["long"] =~ "truncated"
    assert checkpoint["source"] == %{"adapter" => "test", "input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3}

    assert :ok =
             RunLedger.append_agent_event(
               ledger,
               %{
                 event: nil,
                 timestamp: :not_a_datetime,
                 raw: %{
                   "adapter" => "claude_code",
                   "id" => "event-1",
                   "kind" => "event",
                   "method" => "item/commandExecution/outputDelta",
                   "model" => "claude",
                   "name" => "Bash",
                   "role" => "assistant",
                   "timestamp" => "2026-05-10T15:30:12Z",
                   "tool" => "bash",
                   "type" => "result",
                   "status" => "completed",
                   "when" => @now,
                   "tuple" => {:not, "json"},
                   "notes" => ["private list text", %{"status" => "kept"}],
                   "input_tokens" => 1,
                   "output_tokens" => 2,
                   "total_tokens" => 3,
                   "cache_creation_input_tokens" => 4,
                   "cache_read_input_tokens" => 5,
                   "prompt" => "do secret work",
                   "old_string" => "private source",
                   "new_string" => "private source changed",
                   "delta" => "private assistant stream",
                   "summaryText" => "private reasoning summary",
                   "textDelta" => "private text stream",
                   "outputDelta" => "private command output",
                   "output" => "private bare output",
                   "stdout" => "private stdout",
                   "stderr" => "private stderr",
                   "result" => "private final result"
                 }
               },
               timestamp: :not_a_datetime
             )

    artifact_path = Path.join(ledger.run_dir, "artifacts/agent-events.ndjson")
    [line] = artifact_path |> File.read!() |> String.split("\n", trim: true)
    decoded = Jason.decode!(line)
    assert decoded["event"] == "unknown"
    assert decoded["raw"]["adapter"] == "claude_code"
    assert decoded["raw"]["id"] == "event-1"
    assert decoded["raw"]["kind"] == "event"
    assert decoded["raw"]["method"] == "item/commandExecution/outputDelta"
    assert decoded["raw"]["model"] == "claude"
    assert decoded["raw"]["name"] == "Bash"
    assert decoded["raw"]["role"] == "assistant"
    assert decoded["raw"]["timestamp"] == "2026-05-10T15:30:12Z"
    assert decoded["raw"]["tool"] == "bash"
    assert decoded["raw"]["type"] == "result"
    assert decoded["raw"]["status"] == "completed"
    assert decoded["raw"]["when"] == DateTime.to_iso8601(@now)
    assert decoded["raw"]["tuple"] =~ "not"
    assert decoded["raw"]["notes"] == ["[REDACTED]", %{"status" => "kept"}]
    assert decoded["raw"]["input_tokens"] == 1
    assert decoded["raw"]["output_tokens"] == 2
    assert decoded["raw"]["total_tokens"] == 3
    assert decoded["raw"]["cache_creation_input_tokens"] == 4
    assert decoded["raw"]["cache_read_input_tokens"] == 5

    assert :ok = RunLedger.append_agent_event(ledger, %{event: :assistant, raw: [:tool, "safe"]}, timestamp: @now)
    [_first, second_line] = artifact_path |> File.read!() |> String.split("\n", trim: true)
    assert Jason.decode!(second_line)["raw"] == ["tool", "[REDACTED]"]
    assert decoded["raw"]["prompt"] == "[REDACTED]"
    assert decoded["raw"]["old_string"] == "[REDACTED]"
    assert decoded["raw"]["new_string"] == "[REDACTED]"
    assert decoded["raw"]["delta"] == "[REDACTED]"
    assert decoded["raw"]["summaryText"] == "[REDACTED]"
    assert decoded["raw"]["textDelta"] == "[REDACTED]"
    assert decoded["raw"]["outputDelta"] == "[REDACTED]"
    assert decoded["raw"]["output"] == "[REDACTED]"
    assert decoded["raw"]["stdout"] == "[REDACTED]"
    assert decoded["raw"]["stderr"] == "[REDACTED]"
    assert decoded["raw"]["result"] == "[REDACTED]"
    refute line =~ "do secret work"
    refute line =~ "private source"
    refute line =~ "private list text"
    refute line =~ "private assistant stream"
    refute line =~ "private reasoning summary"
    refute line =~ "private text stream"
    refute line =~ "private command output"
    refute line =~ "private bare output"
    refute line =~ "private stdout"
    refute line =~ "private stderr"
    refute line =~ "private final result"

    bad_artifacts_ledger = %{ledger | manifest: Map.put(ledger.manifest, "artifacts", "not-a-list")}
    assert {:ok, _ledger} = RunLedger.link_archive(bad_artifacts_ledger, "/tmp/archive.json")

    unreadable_path = Path.join(workspace_root, "unreadable/manifest.json")
    File.mkdir_p!(unreadable_path)
    assert {:error, :eisdir} = RunLedger.load_manifest(unreadable_path)
  end

  test "append_agent_event writes sanitized capped NDJSON artifacts" do
    workspace_root = tmp_dir("ledger-events")
    issue = issue_fixture()

    assert {:ok, ledger} =
             RunLedger.create_run(issue,
               workspace_root: workspace_root,
               now: @now,
               random_suffix: "deadbeef"
             )

    event = %{
      event: :assistant,
      session_id: "session-1",
      timestamp: @now,
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
      raw: %{
        "api_key" => "super-secret-token",
        "message" => %{"content" => "prompt and file contents"},
        "params" => %{"diff" => "sensitive diff", "turn" => %{"status" => "completed"}},
        "result" => "private result text",
        "safe" => "redacted by default"
      }
    }

    assert :ok = RunLedger.append_agent_event(ledger, event, timestamp: @now)

    artifact_path = Path.join(ledger.run_dir, "artifacts/agent-events.ndjson")
    assert [line] = artifact_path |> File.read!() |> String.split("\n", trim: true)
    decoded = Jason.decode!(line)

    assert decoded["event"] == "assistant"
    assert decoded["session_id"] == "session-1"
    assert decoded["usage"] == %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
    assert decoded["raw"]["api_key"] == "[REDACTED]"
    assert decoded["raw"]["message"] == "[REDACTED]"
    assert decoded["raw"]["params"]["diff"] == "[REDACTED]"
    assert decoded["raw"]["params"]["turn"]["status"] == "completed"
    assert decoded["raw"]["result"] == "[REDACTED]"
    assert decoded["raw"]["safe"] == "[REDACTED]"
    refute line =~ "super-secret-token"
    refute line =~ "prompt and file contents"
    refute line =~ "sensitive diff"
    refute line =~ "private result text"
    refute line =~ "redacted by default"
  end

  defp issue_fixture do
    %Issue{
      id: "issue-401",
      identifier: "MT-401",
      title: "Durable ledger",
      description: "Persist the run lifecycle",
      state: "In Progress",
      url: "https://example.org/issues/MT-401",
      labels: ["P0"],
      priority: 1
    }
  end

  defp decode_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "rondo-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
