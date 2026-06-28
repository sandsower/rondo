defmodule Rondo.RunLedger do
  @moduledoc """
  Durable per-attempt run ledger for orchestrator lifecycle checkpoints.

  The ledger is local diagnostic state. It stores a manifest, small curated
  checkpoint JSON files, and sanitized agent event artifacts under the configured
  workspace root.
  """

  alias Rondo.{Config, FinalReport, Linear.Issue, ProcessProvider, Redaction}

  @schema_version 1
  @events_schema "rondo.events/v0"
  @final_report_relative_path "artifacts/final-report.json"
  @max_string_bytes 2_048
  @max_map_entries 50
  @max_list_entries 50
  @secret_key_pattern ~r/(api[_-]?key|authorization|cookie|password|secret|token)/i
  @content_key_pattern ~r/(command|content|delta|diff|file[_-]?content|input|message|new_string|old_string|output|prompt|result|stderr|stdout|summary[_-]?text|text[_-]?delta)/i

  defstruct [:run_id, :run_dir, :manifest_path, :next_seq, :manifest, :policy_file]

  @type t :: %__MODULE__{
          run_id: String.t(),
          run_dir: Path.t(),
          manifest_path: Path.t(),
          next_seq: pos_integer(),
          manifest: map(),
          policy_file: Path.t() | nil
        }

  @spec create_run(Issue.t() | map(), keyword()) :: {:ok, t()} | {:error, term()}
  def create_run(issue, opts \\ []) when is_map(issue) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    workspace_root = opts |> Keyword.get(:workspace_root, Config.workspace_root()) |> Path.expand()
    safe_identifier = safe_identifier(issue_identifier(issue))
    run_id = run_id(safe_identifier, now, opts)
    run_dir = Path.join([workspace_root, ".rondo_runs", safe_identifier, run_id])
    manifest_path = Path.join(run_dir, "manifest.json")
    workspace = Keyword.get(opts, :workspace, Path.join(workspace_root, safe_identifier))

    with :ok <- File.mkdir_p(Path.join(run_dir, "checkpoints")),
         :ok <- File.mkdir_p(Path.join(run_dir, "artifacts")),
         {:ok, policy_snapshot} <- freeze_policy_file(run_dir, opts),
         manifest = build_manifest(issue, opts, now, run_id, run_dir, workspace_root, workspace, policy_snapshot),
         :ok <- write_json_file(manifest_path, manifest) do
      {:ok,
       %__MODULE__{
         run_id: run_id,
         run_dir: run_dir,
         manifest_path: manifest_path,
         next_seq: 1,
         manifest: manifest,
         policy_file: Map.fetch!(policy_snapshot, "policy_file")
       }}
    end
  end

  # Freezes the effective action-policy file into the run dir so the run is
  # governed by exactly the contents the manifest records, even if the source
  # file changes mid-run. Fail-closed: a set-but-unreadable policy file aborts
  # ledger creation instead of silently falling back to the builtin policy.
  defp freeze_policy_file(run_dir, opts) do
    case Keyword.get(opts, :action_policy_policy_file, Config.action_policy_policy_file()) do
      nil ->
        {:ok, %{"policy_file" => nil, "policy_file_source" => nil, "policy_file_sha256" => nil}}

      source ->
        source = Path.expand(source)
        frozen = Path.join(run_dir, "artifacts/action-policy.json")

        with {:ok, contents} <- File.read(source),
             :ok <- File.write(frozen, contents) do
          {:ok,
           %{
             "policy_file" => frozen,
             "policy_file_source" => source,
             "policy_file_sha256" => :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
           }}
        else
          {:error, reason} -> {:error, {:policy_file_freeze_failed, source, reason}}
        end
    end
  end

  @spec write_checkpoint(t(), atom() | String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def write_checkpoint(%__MODULE__{} = ledger, kind, payload, opts \\ []) when is_map(payload) do
    timestamp = opts |> Keyword.get(:timestamp, DateTime.utc_now()) |> datetime_to_iso()
    kind_string = kind_to_string(kind)
    seq = ledger.next_seq
    relative_path = Path.join("checkpoints", checkpoint_filename(seq, kind_string))
    checkpoint_path = Path.join(ledger.run_dir, relative_path)

    checkpoint = %{
      "seq" => seq,
      "kind" => kind_string,
      "timestamp" => timestamp,
      "source" => sanitize_value(Keyword.get(opts, :source, %{})),
      "payload" => sanitize_value(payload)
    }

    checkpoint_index = %{
      "seq" => seq,
      "kind" => kind_string,
      "path" => relative_path,
      "timestamp" => timestamp
    }

    manifest_update = Keyword.get(opts, :manifest_update, & &1)

    manifest =
      ledger.manifest
      |> Map.update("checkpoints", [checkpoint_index], &(&1 ++ [checkpoint_index]))
      |> put_in(["timestamps", "updated_at"], timestamp)
      |> manifest_update.()

    with :ok <- write_json_file(checkpoint_path, checkpoint),
         :ok <- write_json_file(ledger.manifest_path, manifest) do
      {:ok, %{ledger | next_seq: seq + 1, manifest: manifest}}
    end
  end

  @spec append_agent_event(t(), map(), keyword()) :: :ok | {:error, term()}
  def append_agent_event(%__MODULE__{} = ledger, event, opts \\ []) when is_map(event) do
    timestamp = opts |> Keyword.get(:timestamp, Map.get(event, :timestamp, DateTime.utc_now())) |> datetime_to_iso()

    artifact = agent_event_payload(event, timestamp)

    path = Path.join(ledger.run_dir, "artifacts/agent-events.ndjson")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(artifact) do
      File.write(path, json <> "\n", [:append])
    end
  end

  @spec record_action_policy_decision(t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def record_action_policy_decision(%__MODULE__{} = ledger, envelope, opts \\ []) when is_map(envelope) do
    payload =
      envelope
      |> Map.merge(%{
        "human_outcome" => Keyword.get(opts, :human_outcome),
        "side_effect_status" => Keyword.get(opts, :side_effect_status)
      })
      |> drop_nil_values()

    write_checkpoint(ledger, :action_policy_decision, payload, source: %{policy: "beislid_action_policy"})
  end

  @spec update_agent_metadata(t(), map()) :: {:ok, t()} | {:error, term()}
  def update_agent_metadata(%__MODULE__{} = ledger, metadata) when is_map(metadata) do
    agent_metadata = metadata |> sanitize_value() |> drop_nil_values()

    if agent_metadata == %{} do
      {:ok, ledger}
    else
      timestamp = DateTime.utc_now() |> datetime_to_iso()

      manifest =
        ledger
        |> latest_manifest()
        |> update_in(["agent"], fn
          agent when is_map(agent) -> Map.merge(agent, agent_metadata)
          _other -> agent_metadata
        end)
        |> put_in(["timestamps", "updated_at"], timestamp)

      with :ok <- write_json_file(ledger.manifest_path, manifest) do
        {:ok, %{ledger | manifest: manifest}}
      end
    end
  end

  @spec pause_run(t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def pause_run(%__MODULE__{} = ledger, interrupt, opts \\ []) when is_map(interrupt) do
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    iso_timestamp = datetime_to_iso(timestamp)
    sanitized_interrupt = sanitize_value(interrupt)

    manifest_update = fn manifest ->
      manifest
      |> Map.put("status", "paused")
      |> Map.put("interrupt", sanitized_interrupt)
      |> put_in(["timestamps", "updated_at"], iso_timestamp)
      |> put_in(["timestamps", "paused_at"], iso_timestamp)
    end

    checkpoint_opts =
      opts
      |> Keyword.put(:timestamp, timestamp)
      |> Keyword.put(:manifest_update, manifest_update)
      |> Keyword.put_new(:source, %{interrupt: "human"})

    write_checkpoint(ledger, :interrupt_created, interrupt, checkpoint_opts)
  end

  @spec complete_run(t(), String.t() | atom(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def complete_run(%__MODULE__{} = ledger, status, payload, opts \\ []) when is_map(payload) do
    status_string = kind_to_string(status)
    kind = terminal_checkpoint_kind(status_string)
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())

    with {:ok, ledger} <- write_checkpoint(ledger, kind, payload, Keyword.put(opts, :timestamp, timestamp)) do
      iso_timestamp = datetime_to_iso(timestamp)

      manifest =
        ledger.manifest
        |> Map.put("status", status_string)
        |> maybe_put_terminal_failure_classification(status_string, opts)
        |> put_in(["timestamps", "updated_at"], iso_timestamp)
        |> put_in(["timestamps", "finished_at"], iso_timestamp)

      with :ok <- write_json_file(ledger.manifest_path, manifest) do
        {:ok, %{ledger | manifest: manifest}}
      end
    end
  end

  defp maybe_put_terminal_failure_classification(manifest, "failed", opts) do
    Map.put(manifest, "failure_classification", Keyword.get(opts, :failure_classification, "task_failure"))
  end

  defp maybe_put_terminal_failure_classification(manifest, _status, _opts), do: manifest

  @spec link_archive(t(), Path.t() | nil) :: {:ok, t()} | {:error, term()}
  def link_archive(%__MODULE__{} = ledger, nil), do: {:ok, ledger}

  def link_archive(%__MODULE__{} = ledger, archive_path) when is_binary(archive_path) do
    link_artifacts(ledger, [%{"kind" => "archive", "path" => archive_path}])
  end

  @spec link_artifacts(t(), [map()]) :: {:ok, t()} | {:error, term()}
  def link_artifacts(%__MODULE__{} = ledger, artifacts) when is_list(artifacts) do
    normalized_artifacts =
      artifacts
      |> Enum.filter(&valid_artifact?/1)
      |> Enum.map(&sanitize_value/1)

    if normalized_artifacts == [] do
      {:ok, ledger}
    else
      timestamp = DateTime.utc_now() |> datetime_to_iso()

      manifest =
        ledger.manifest
        |> Map.update("artifacts", normalized_artifacts, fn existing ->
          Enum.reduce(normalized_artifacts, existing, &upsert_artifact(&2, &1))
        end)
        |> put_in(["timestamps", "updated_at"], timestamp)

      with :ok <- write_json_file(ledger.manifest_path, manifest) do
        {:ok, %{ledger | manifest: manifest}}
      end
    end
  end

  @spec load_manifest(Path.t()) :: {:ok, map()} | {:error, :missing | :invalid_json | :invalid_manifest | term()}
  def load_manifest(path) when is_binary(path) do
    manifest_path = manifest_path(path)

    with true <- File.exists?(manifest_path),
         {:ok, json} <- File.read(manifest_path),
         {:ok, manifest} <- decode_json(json),
         :ok <- validate_manifest(manifest) do
      {:ok, manifest}
    else
      false -> {:error, :missing}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, :invalid_manifest} -> {:error, :invalid_manifest}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec checkpoint_payload_for_agent_update(map()) :: map()
  def checkpoint_payload_for_agent_update(update) when is_map(update) do
    %{
      event: Map.get(update, :event, Map.get(update, "event")),
      adapter: agent_update_value(update, :adapter),
      run_ref: sanitize_value(agent_update_value(update, :run_ref)),
      session_id: sanitize_value(Map.get(update, :session_id, Map.get(update, "session_id"))),
      usage: sanitize_value(Map.get(update, :usage, Map.get(update, "usage"))),
      capabilities: sanitize_value(agent_update_value(update, :capabilities)),
      final_report: sanitize_value(agent_update_value(update, :final_report)),
      diff_source: sanitize_value(agent_update_value(update, :diff_source)),
      raw: sanitize_agent_raw(Map.get(update, :raw, Map.get(update, "raw", %{})))
    }
    |> drop_nil_values()
  end

  @spec checkpoint_source_for_agent_update(map()) :: map()
  def checkpoint_source_for_agent_update(update) when is_map(update) do
    %{
      adapter: agent_update_value(update, :adapter) || "claude_code",
      event: raw_method(update) || kind_to_string(Map.get(update, :event, Map.get(update, "event")))
    }
  end

  @spec agent_metadata_for_agent_update(map()) :: map()
  def agent_metadata_for_agent_update(update) when is_map(update) do
    %{
      "adapter" => agent_update_value(update, :adapter),
      "run_ref" => agent_update_value(update, :run_ref),
      "session_id" => Map.get(update, :session_id, Map.get(update, "session_id")),
      "usage" => Map.get(update, :usage, Map.get(update, "usage")),
      "capabilities" => agent_update_value(update, :capabilities),
      "final_report" => agent_update_value(update, :final_report),
      "diff_source" => agent_update_value(update, :diff_source),
      "model_routing" => agent_update_value(update, :model_routing)
    }
    |> drop_nil_values()
  end

  @spec checkpoint_kind_for_agent_update(map()) :: String.t() | nil
  def checkpoint_kind_for_agent_update(update) when is_map(update) do
    update
    |> raw_method()
    |> checkpoint_kind_for_method()
    |> case do
      nil -> update |> Map.get(:event, Map.get(update, "event")) |> checkpoint_kind_for_event()
      kind -> kind
    end
  end

  defp checkpoint_kind_for_method("turn/started"), do: "turn_started"
  defp checkpoint_kind_for_method("turn/completed"), do: "turn_completed"
  defp checkpoint_kind_for_method("turn/failed"), do: "turn_failed"
  defp checkpoint_kind_for_method("turn/cancelled"), do: "turn_cancelled"
  defp checkpoint_kind_for_method("turn/diff/updated"), do: "edit_batch"
  defp checkpoint_kind_for_method(_method), do: nil

  defp checkpoint_kind_for_event(:claude_starting), do: "workspace_ready"
  defp checkpoint_kind_for_event("claude_starting"), do: "workspace_ready"
  defp checkpoint_kind_for_event(:session_started), do: "turn_started"
  defp checkpoint_kind_for_event("session_started"), do: "turn_started"
  defp checkpoint_kind_for_event(:result), do: "turn_completed"
  defp checkpoint_kind_for_event("result"), do: "turn_completed"
  defp checkpoint_kind_for_event(:invocation_completed), do: "turn_completed"
  defp checkpoint_kind_for_event("invocation_completed"), do: "turn_completed"
  defp checkpoint_kind_for_event(:invocation_failed), do: "turn_failed"
  defp checkpoint_kind_for_event("invocation_failed"), do: "turn_failed"
  defp checkpoint_kind_for_event(:gates_completed), do: "gates_completed"
  defp checkpoint_kind_for_event("gates_completed"), do: "gates_completed"
  defp checkpoint_kind_for_event(:gates_reused), do: "gates_reused"
  defp checkpoint_kind_for_event("gates_reused"), do: "gates_reused"
  defp checkpoint_kind_for_event(_event), do: nil

  @doc "Returns the normalized agent event JSONL schema identifier."
  @spec events_schema() :: String.t()
  def events_schema, do: @events_schema

  @doc "Returns the run-dir-relative path of the validated final report artifact."
  @spec final_report_relative_path() :: String.t()
  def final_report_relative_path, do: @final_report_relative_path

  @spec record_final_report(t(), term()) :: {:ok, t(), :valid | :invalid | :missing} | {:error, term()}
  def record_final_report(%__MODULE__{} = ledger, source) do
    case FinalReport.extract(source) do
      {:ok, report} ->
        persist_valid_final_report(ledger, report)

      {:error, :missing} ->
        record_final_report_validation(ledger, :missing, ["final report missing or not parseable as #{FinalReport.schema()} JSON"])

      {:error, {:invalid, errors}} ->
        record_final_report_validation(ledger, :invalid, errors)
    end
  end

  defp persist_valid_final_report(ledger, report) do
    path = Path.join(ledger.run_dir, @final_report_relative_path)

    with :ok <- write_json_file(path, sanitize_value(report)),
         {:ok, ledger} <- link_artifacts(ledger, [%{"kind" => "final_report", "path" => @final_report_relative_path}]) do
      record_final_report_validation(ledger, :valid, [])
    end
  end

  defp record_final_report_validation(ledger, status, errors) do
    status_string = Atom.to_string(status)
    sanitized_errors = sanitize_value(errors)

    validation =
      %{
        "status" => status_string,
        "errors" => sanitized_errors,
        "path" => if(status == :valid, do: @final_report_relative_path)
      }
      |> drop_nil_values()

    manifest_update = fn manifest ->
      manifest
      |> Map.put("final_report", validation)
      |> maybe_put_final_report_classification(status)
    end

    checkpoint_payload = %{schema: FinalReport.schema(), status: status_string, errors: sanitized_errors}

    case write_checkpoint(ledger, :final_report_validated, checkpoint_payload,
           source: %{validator: FinalReport.schema()},
           manifest_update: manifest_update
         ) do
      {:ok, ledger} -> {:ok, ledger, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_final_report_classification(manifest, :valid) do
    case Map.get(manifest, "failure_classification") do
      "final_report_missing" -> Map.delete(manifest, "failure_classification")
      "final_report_invalid" -> Map.delete(manifest, "failure_classification")
      _other -> manifest
    end
  end

  defp maybe_put_final_report_classification(manifest, :missing), do: Map.put(manifest, "failure_classification", "final_report_missing")
  defp maybe_put_final_report_classification(manifest, :invalid), do: Map.put(manifest, "failure_classification", "final_report_invalid")

  defp agent_event_payload(event, timestamp) do
    %{
      "schema" => @events_schema,
      "timestamp" => timestamp,
      "event" => event |> Map.get(:event, Map.get(event, "event")) |> kind_to_string(),
      "adapter" => sanitize_value(Map.get(event, :adapter, Map.get(event, "adapter"))),
      "run_ref" => sanitize_value(Map.get(event, :run_ref, Map.get(event, "run_ref"))),
      "session_id" => sanitize_value(Map.get(event, :session_id, Map.get(event, "session_id"))),
      "usage" => sanitize_value(Map.get(event, :usage, Map.get(event, "usage"))),
      "raw" => event |> Map.get(:raw, Map.get(event, "raw", %{})) |> sanitize_agent_raw()
    }
  end

  defp build_manifest(issue, opts, now, run_id, run_dir, workspace_root, workspace, policy_snapshot) do
    iso_timestamp = datetime_to_iso(now)

    %{
      "schema_version" => @schema_version,
      "run_id" => run_id,
      "status" => "running",
      "run_dir" => Path.expand(run_dir),
      "issue" => sanitize_value(issue_snapshot(issue)),
      "repo" => repo_snapshot(workspace_root, workspace, opts),
      "tracker" => %{"adapter" => Keyword.get(opts, :tracker_adapter, Config.tracker_kind())},
      "agent" => %{
        "adapter" => Keyword.get(opts, :agent_adapter, Config.agent_adapter()),
        "session_id" => Keyword.get(opts, :agent_session_id),
        "run_ref" => Keyword.get(opts, :agent_run_ref),
        "capabilities" => Keyword.get(opts, :agent_capabilities),
        "final_report" => Keyword.get(opts, :agent_final_report),
        "diff_source" => Keyword.get(opts, :agent_diff_source),
        "model_routing" => Keyword.get(opts, :model_routing)
      },
      "process_provider" => process_provider_snapshot(opts),
      "mode" => mode_snapshot(opts),
      "action_policy" =>
        Map.merge(
          %{
            "provider" => "beislid",
            "run_mode" => Keyword.get(opts, :action_policy_run_mode, Config.action_policy_run_mode())
          },
          policy_snapshot
        ),
      "timestamps" => %{
        "created_at" => iso_timestamp,
        "updated_at" => iso_timestamp,
        "started_at" => opts |> Keyword.get(:started_at, iso_timestamp) |> datetime_to_iso(),
        "finished_at" => nil
      },
      "checkpoints" => [],
      "artifacts" => [%{"kind" => "agent_events", "path" => "artifacts/agent-events.ndjson"}]
    }
    |> maybe_put_source_contract(Keyword.get(opts, :source_contract))
  end

  defp maybe_put_source_contract(manifest, nil), do: manifest

  defp maybe_put_source_contract(manifest, source_contract) when is_map(source_contract) do
    Map.put(manifest, "source_contract", sanitize_value(source_contract))
  end

  defp maybe_put_source_contract(manifest, _source_contract), do: manifest

  defp issue_snapshot(issue) do
    %{
      "id" => issue_value(issue, :id),
      "identifier" => issue_value(issue, :identifier),
      "title" => issue_value(issue, :title),
      "description" => issue_value(issue, :description),
      "state" => issue_value(issue, :state),
      "url" => issue_value(issue, :url),
      "labels" => issue_value(issue, :labels, []),
      "priority" => issue_value(issue, :priority)
    }
  end

  defp repo_snapshot(workspace_root, workspace, opts) do
    runner = Keyword.get(opts, :git_runner, &run_git/2)

    %{
      "workspace_root" => Path.expand(workspace_root),
      "workspace" => Path.expand(workspace),
      "base_commit" => workspace_git_value(runner, workspace, ["rev-parse", "HEAD"]),
      "base_branch" => workspace_git_value(runner, workspace, ["rev-parse", "--abbrev-ref", "HEAD"])
    }
  end

  defp workspace_git_value(runner, workspace, args) do
    with true <- File.dir?(workspace),
         {output, 0} <- runner.(args, workspace) do
      String.trim(output)
    else
      _other -> nil
    end
  end

  defp run_git(args, workspace) do
    System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
  end

  defp process_provider_snapshot(opts) do
    provider =
      opts
      |> Keyword.get(:process_provider, Config.process_provider_kind())
      |> ProcessProvider.provider_module()

    %{
      "kind" => provider.id(),
      "capabilities" => provider.capabilities(),
      "probe" => provider.probe([])
    }
    |> sanitize_value()
  end

  defp mode_snapshot(opts) do
    %{
      "agent_max_turns" => Keyword.get(opts, :agent_max_turns, Config.agent_max_turns()),
      "claude_max_turns" => Keyword.get(opts, :claude_max_turns, Config.claude_max_turns()),
      "claude_permission_mode" => Keyword.get(opts, :claude_permission_mode, Config.claude_permission_mode()),
      "claude_dangerously_skip_permissions" => Keyword.get(opts, :claude_dangerously_skip_permissions, Config.claude_dangerously_skip_permissions?()),
      "claude_model" => Keyword.get(opts, :claude_model, Config.claude_model()),
      "claude_allowed_tools" => Keyword.get(opts, :claude_allowed_tools, Config.claude_allowed_tools())
    }
  end

  defp write_json_file(path, payload) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(payload) do
      File.write(path, json)
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Jason.DecodeError{} = error} -> {:error, error}
    end
  end

  defp latest_manifest(%__MODULE__{} = ledger) do
    with {:ok, json} <- File.read(ledger.manifest_path),
         {:ok, manifest} <- decode_json(json),
         :ok <- validate_manifest(manifest) do
      manifest
    else
      _reason -> ledger.manifest
    end
  end

  defp validate_manifest(%{"schema_version" => @schema_version, "run_id" => run_id, "status" => status, "run_dir" => run_dir, "checkpoints" => checkpoints})
       when is_binary(run_id) and is_binary(status) and is_binary(run_dir) and is_list(checkpoints),
       do: :ok

  defp validate_manifest(_manifest), do: {:error, :invalid_manifest}

  defp manifest_path(path) do
    case Path.basename(path) do
      "manifest.json" -> path
      _ -> Path.join(path, "manifest.json")
    end
  end

  defp run_id(identifier, %DateTime{} = now, opts) do
    Enum.join([identifier, file_timestamp(now), random_suffix(opts)], "-")
  end

  defp random_suffix(opts) do
    case Keyword.get(opts, :random_suffix) do
      suffix when is_binary(suffix) -> suffix
      _ -> :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    end
  end

  defp checkpoint_filename(seq, kind) do
    seq_string = seq |> Integer.to_string() |> String.pad_leading(4, "0")
    safe_kind = String.replace(kind, ~r/[^a-zA-Z0-9._-]/, "_")
    "#{seq_string}-#{safe_kind}.json"
  end

  defp terminal_checkpoint_kind("completed"), do: :completed
  defp terminal_checkpoint_kind("terminated"), do: :terminated
  defp terminal_checkpoint_kind(_status), do: :failed

  defp upsert_artifact(artifacts, artifact) when is_list(artifacts) do
    if Enum.any?(artifacts, &(&1 == artifact)), do: artifacts, else: artifacts ++ [artifact]
  end

  defp upsert_artifact(_artifacts, artifact), do: [artifact]

  defp valid_artifact?(%{"kind" => kind, "path" => path}) when is_binary(kind) and is_binary(path), do: true
  defp valid_artifact?(%{kind: kind, path: path}) when is_binary(kind) and is_binary(path), do: true
  defp valid_artifact?(_artifact), do: false

  defp issue_identifier(issue), do: issue_value(issue, :identifier) || issue_value(issue, :id) || "issue"

  defp issue_value(issue, key, default \\ nil) when is_atom(key) do
    Map.get(issue, key) || Map.get(issue, Atom.to_string(key), default)
  end

  defp safe_identifier(identifier) do
    identifier
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp file_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp datetime_to_iso(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp datetime_to_iso(value) when is_binary(value), do: value
  defp datetime_to_iso(_value), do: DateTime.utc_now() |> datetime_to_iso()

  defp agent_update_value(update, key) when is_map(update) and is_atom(key) do
    Map.get(update, key) ||
      Map.get(update, Atom.to_string(key)) ||
      update
      |> Map.get(:raw, Map.get(update, "raw", %{}))
      |> raw_agent_value(key)
  end

  defp raw_agent_value(raw, key) when is_map(raw) and is_atom(key) do
    Map.get(raw, key) || Map.get(raw, Atom.to_string(key))
  end

  defp raw_agent_value(_raw, _key), do: nil

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp raw_method(%{raw: raw}), do: raw_method(raw)
  defp raw_method(%{"raw" => raw}), do: raw_method(raw)
  defp raw_method(%{"method" => method}) when is_binary(method), do: method
  defp raw_method(%{method: method}) when is_binary(method), do: method
  defp raw_method(_raw), do: nil

  defp kind_to_string(nil), do: "unknown"
  defp kind_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp kind_to_string(value) when is_binary(value), do: value
  defp kind_to_string(value), do: inspect(value)

  defp sanitize_value(%DateTime{} = datetime), do: datetime_to_iso(datetime)

  defp sanitize_value(value) when is_binary(value), do: cap_string(value)
  defp sanitize_value(value) when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value), do: value
  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize_value(value) when is_list(value) do
    value
    |> Enum.take(@max_list_entries)
    |> Enum.map(&sanitize_value/1)
  end

  defp sanitize_value(value) when is_map(value) do
    value
    |> Enum.take(@max_map_entries)
    |> Map.new(fn {key, nested_value} ->
      string_key = kind_to_string(key)

      if secret_key?(string_key) do
        {string_key, "[REDACTED]"}
      else
        {string_key, sanitize_value(nested_value)}
      end
    end)
  end

  defp sanitize_value(value), do: value |> inspect() |> cap_string()

  defp sanitize_agent_raw(%DateTime{} = datetime), do: datetime_to_iso(datetime)
  defp sanitize_agent_raw(value) when is_binary(value), do: cap_string(value)
  defp sanitize_agent_raw(value) when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value), do: value
  defp sanitize_agent_raw(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize_agent_raw(value) when is_list(value) do
    value
    |> Enum.take(@max_list_entries)
    |> Enum.map(fn
      item when is_binary(item) -> "[REDACTED]"
      item -> sanitize_agent_raw(item)
    end)
  end

  defp sanitize_agent_raw(value) when is_map(value) do
    value
    |> Enum.take(@max_map_entries)
    |> Map.new(fn {key, nested_value} ->
      string_key = kind_to_string(key)

      cond do
        secret_key?(string_key) -> {string_key, "[REDACTED]"}
        content_key?(string_key) -> {string_key, "[REDACTED]"}
        is_binary(nested_value) and not safe_raw_key?(string_key) -> {string_key, "[REDACTED]"}
        true -> {string_key, sanitize_agent_raw(nested_value)}
      end
    end)
  end

  defp sanitize_agent_raw(value), do: value |> inspect() |> cap_string()

  defp secret_key?("input_tokens"), do: false
  defp secret_key?("output_tokens"), do: false
  defp secret_key?("total_tokens"), do: false
  defp secret_key?("cache_creation_input_tokens"), do: false
  defp secret_key?("cache_read_input_tokens"), do: false
  defp secret_key?(key), do: Regex.match?(@secret_key_pattern, key)

  defp content_key?("input_tokens"), do: false
  defp content_key?("output_tokens"), do: false
  defp content_key?("total_tokens"), do: false
  defp content_key?("cache_creation_input_tokens"), do: false
  defp content_key?("cache_read_input_tokens"), do: false
  defp content_key?(key), do: Regex.match?(@content_key_pattern, key)

  defp safe_raw_key?("adapter"), do: true
  defp safe_raw_key?("id"), do: true
  defp safe_raw_key?("kind"), do: true
  defp safe_raw_key?("method"), do: true
  defp safe_raw_key?("model"), do: true
  defp safe_raw_key?("name"), do: true
  defp safe_raw_key?("role"), do: true
  defp safe_raw_key?("session_id"), do: true
  defp safe_raw_key?("status"), do: true
  defp safe_raw_key?("subtype"), do: true
  defp safe_raw_key?("timestamp"), do: true
  defp safe_raw_key?("tool"), do: true
  defp safe_raw_key?("type"), do: true
  defp safe_raw_key?(_key), do: false

  defp cap_string(value) do
    value
    |> Redaction.redact()
    |> truncate_string()
  end

  defp truncate_string(value) do
    if byte_size(value) <= @max_string_bytes do
      value
    else
      binary_part(value, 0, @max_string_bytes) <> "... (truncated)"
    end
  end
end
