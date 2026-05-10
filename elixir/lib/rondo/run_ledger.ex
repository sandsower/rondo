defmodule Rondo.RunLedger do
  @moduledoc """
  Durable per-attempt run ledger for orchestrator lifecycle checkpoints.

  The ledger is local diagnostic state. It stores a manifest, small curated
  checkpoint JSON files, and sanitized agent event artifacts under the configured
  workspace root.
  """

  alias Rondo.{Config, Linear.Issue}

  @schema_version 1
  @max_string_bytes 2_048
  @max_map_entries 50
  @max_list_entries 50
  @secret_key_pattern ~r/(api[_-]?key|authorization|cookie|password|secret|token)/i
  @content_key_pattern ~r/(command|content|delta|diff|file[_-]?content|input|message|new_string|old_string|output|prompt|result|stderr|stdout|summary[_-]?text|text[_-]?delta)/i

  defstruct [:run_id, :run_dir, :manifest_path, :next_seq, :manifest]

  @type t :: %__MODULE__{
          run_id: String.t(),
          run_dir: Path.t(),
          manifest_path: Path.t(),
          next_seq: pos_integer(),
          manifest: map()
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

    manifest = build_manifest(issue, opts, now, run_id, run_dir, workspace_root, workspace)

    ledger = %__MODULE__{
      run_id: run_id,
      run_dir: run_dir,
      manifest_path: manifest_path,
      next_seq: 1,
      manifest: manifest
    }

    with :ok <- File.mkdir_p(Path.join(run_dir, "checkpoints")),
         :ok <- File.mkdir_p(Path.join(run_dir, "artifacts")),
         :ok <- write_json_file(manifest_path, manifest) do
      {:ok, ledger}
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

    manifest =
      ledger.manifest
      |> Map.update("checkpoints", [checkpoint_index], &(&1 ++ [checkpoint_index]))
      |> put_in(["timestamps", "updated_at"], timestamp)

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
        |> put_in(["timestamps", "updated_at"], iso_timestamp)
        |> put_in(["timestamps", "finished_at"], iso_timestamp)

      with :ok <- write_json_file(ledger.manifest_path, manifest) do
        {:ok, %{ledger | manifest: manifest}}
      end
    end
  end

  @spec link_archive(t(), Path.t() | nil) :: {:ok, t()} | {:error, term()}
  def link_archive(%__MODULE__{} = ledger, nil), do: {:ok, ledger}

  def link_archive(%__MODULE__{} = ledger, archive_path) when is_binary(archive_path) do
    artifact = %{"kind" => "archive", "path" => archive_path}
    timestamp = DateTime.utc_now() |> datetime_to_iso()

    manifest =
      ledger.manifest
      |> Map.update("artifacts", [artifact], &upsert_artifact(&1, artifact))
      |> put_in(["timestamps", "updated_at"], timestamp)

    with :ok <- write_json_file(ledger.manifest_path, manifest) do
      {:ok, %{ledger | manifest: manifest}}
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
      session_id: Map.get(update, :session_id, Map.get(update, "session_id")),
      usage: sanitize_value(Map.get(update, :usage, Map.get(update, "usage"))),
      raw: sanitize_agent_raw(Map.get(update, :raw, Map.get(update, "raw", %{})))
    }
  end

  @spec checkpoint_source_for_agent_update(map()) :: map()
  def checkpoint_source_for_agent_update(update) when is_map(update) do
    %{
      adapter: "claude_code",
      event: raw_method(update) || kind_to_string(Map.get(update, :event, Map.get(update, "event")))
    }
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
  defp checkpoint_kind_for_event(_event), do: nil

  defp agent_event_payload(event, timestamp) do
    %{
      "timestamp" => timestamp,
      "event" => event |> Map.get(:event, Map.get(event, "event")) |> kind_to_string(),
      "session_id" => Map.get(event, :session_id, Map.get(event, "session_id")),
      "usage" => sanitize_value(Map.get(event, :usage, Map.get(event, "usage"))),
      "raw" => event |> Map.get(:raw, Map.get(event, "raw", %{})) |> sanitize_agent_raw()
    }
  end

  defp build_manifest(issue, opts, now, run_id, run_dir, workspace_root, workspace) do
    iso_timestamp = datetime_to_iso(now)

    %{
      "schema_version" => @schema_version,
      "run_id" => run_id,
      "status" => "running",
      "run_dir" => Path.expand(run_dir),
      "issue" => issue_snapshot(issue),
      "repo" => %{
        "workspace_root" => Path.expand(workspace_root),
        "workspace" => Path.expand(workspace)
      },
      "tracker" => %{"adapter" => Keyword.get(opts, :tracker_adapter, Config.tracker_kind())},
      "agent" => %{
        "adapter" => Keyword.get(opts, :agent_adapter, "claude_code"),
        "session_id" => Keyword.get(opts, :agent_session_id)
      },
      "mode" => mode_snapshot(opts),
      "timestamps" => %{
        "created_at" => iso_timestamp,
        "updated_at" => iso_timestamp,
        "started_at" => opts |> Keyword.get(:started_at, iso_timestamp) |> datetime_to_iso(),
        "finished_at" => nil
      },
      "checkpoints" => [],
      "artifacts" => [%{"kind" => "agent_events", "path" => "artifacts/agent-events.ndjson"}]
    }
  end

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
    if byte_size(value) <= @max_string_bytes do
      value
    else
      binary_part(value, 0, @max_string_bytes) <> "... (truncated)"
    end
  end
end
