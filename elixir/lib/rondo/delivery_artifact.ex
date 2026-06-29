defmodule Rondo.DeliveryArtifact do
  @moduledoc """
  Builds the completed-run delivery artifact linked from a run ledger manifest.

  The artifact is a portable, redacted summary of one completed run. It links to
  existing run-ledger evidence instead of embedding raw logs, diffs, prompts, or
  other content-heavy data.
  """

  alias Rondo.{Redaction, RunLedger}

  @schema "rondo-delivery-artifact-v0"
  @relative_path "artifacts/delivery-artifact.json"
  @max_string_bytes 2_048
  @secret_key_pattern ~r/(api[_-]?key|authorization|cookie|password|secret|token)/i

  @doc "Returns the delivery artifact schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Returns the run-dir-relative path of the delivery artifact."
  @spec relative_path() :: String.t()
  def relative_path, do: @relative_path

  @doc "Builds the delivery artifact from the latest manifest on disk."
  @spec build(RunLedger.t()) :: map()
  def build(%RunLedger{} = ledger) do
    build_from_manifest(ledger, latest_manifest(ledger))
  end

  @doc "Writes and links the delivery artifact for a completed run ledger."
  @spec write(RunLedger.t()) ::
          {:ok, RunLedger.t(), :written | :skipped_not_completed | :blocked_patch_contains_secret} | {:error, term()}
  def write(%RunLedger{} = ledger) do
    manifest = latest_manifest(ledger)

    cond do
      Map.get(manifest, "status") != "completed" ->
        {:ok, %{ledger | manifest: manifest}, :skipped_not_completed}

      Map.get(manifest, "failure_classification") == "patch_contains_secret" ->
        {:ok, %{ledger | manifest: manifest}, :blocked_patch_contains_secret}

      true ->
        write_completed(%{ledger | manifest: manifest})
    end
  end

  defp write_completed(ledger) do
    artifact = build_from_manifest(ledger, ledger.manifest)
    path = Path.join(ledger.run_dir, @relative_path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(artifact),
         :ok <- File.write(path, json),
         {:ok, ledger} <- RunLedger.link_artifacts(ledger, [%{"kind" => "delivery_artifact", "path" => @relative_path}]) do
      {:ok, ledger, :written}
    end
  end

  defp build_from_manifest(ledger, manifest) do
    final_report = final_report(ledger, manifest)
    {archive_path, archive_requires_local?} = archive_output(manifest)

    %{
      "schema" => @schema,
      "run" => run_section(manifest),
      "source" => source_section(manifest),
      "summary" => summary_section(final_report, manifest),
      "outputs" => outputs_section(manifest, archive_path),
      "proof" => proof_section(ledger, manifest, final_report),
      "interrupts" => interrupts_section(ledger, manifest),
      "human_decisions" => human_decisions_section(ledger, manifest),
      "risks" => list_field(final_report, "risks"),
      "deferred_work" => list_field(final_report, "deferred_work"),
      "memory_lesson_candidates" => list_field(final_report, "memory_lesson_candidates"),
      "redaction" => redaction_section(),
      "portability" => portability_section(manifest, archive_requires_local?)
    }
    |> sanitize_value()
  end

  defp run_section(manifest) do
    timestamps = Map.get(manifest, "timestamps", %{})

    %{
      "run_id" => Map.get(manifest, "run_id"),
      "status" => Map.get(manifest, "status"),
      "issue" => issue_summary(Map.get(manifest, "issue", %{})),
      "started_at" => Map.get(timestamps, "started_at"),
      "finished_at" => Map.get(timestamps, "finished_at")
    }
  end

  defp issue_summary(issue) when is_map(issue) do
    Map.take(issue, ["id", "identifier", "title", "url", "labels"])
  end

  defp source_section(manifest) do
    source_contract = Map.get(manifest, "source_contract")
    issue = Map.get(manifest, "issue", %{})

    %{
      "contract_schema" => source_value(source_contract, "schema") || "linear-ticket",
      "contract_id" => source_contract_id(source_contract) || Map.get(issue, "identifier") || Map.get(issue, "id"),
      "contract_path" => source_value(source_contract, "path"),
      "contract_sha256" => source_value(source_contract, "sha256"),
      "envelope_schema" => source_value(source_contract, "envelope_schema") || nested_source_value(source_contract, "envelope", "schema"),
      "envelope_id" => source_value(source_contract, "envelope_id") || nested_source_value(source_contract, "envelope", "id"),
      "envelope_sha256" => source_value(source_contract, "envelope_sha256") || nested_source_value(source_contract, "envelope", "sha256"),
      "parent_contract" => source_value(source_contract, "parent_contract")
    }
  end

  defp source_contract_id(source_contract) do
    source_value(source_contract, "contract_id") || source_value(source_contract, "slice_id") || source_value(source_contract, "id") ||
      source_value(source_contract, "identifier")
  end

  defp source_value(source, key) when is_map(source), do: Map.get(source, key) || Map.get(source, String.to_atom(key))
  defp source_value(_source, _key), do: nil

  defp nested_source_value(source, parent, key) do
    source
    |> source_value(parent)
    |> source_value(key)
  end

  defp summary_section(final_report, manifest) do
    %{
      "title" => summary_title(final_report, manifest),
      "status" => Map.get(manifest, "status"),
      "final_report" => Map.get(final_report, "summary"),
      "changed_files" => list_field(final_report, "changed_files"),
      "commits" => list_field(final_report, "commits"),
      "verification_summary" => verification_summary(final_report, manifest)
    }
  end

  defp summary_title(final_report, manifest) do
    Map.get(final_report, "title") || Map.get(final_report, "summary") || "Completed Rondo run #{Map.get(manifest, "run_id")}"
  end

  defp verification_summary(final_report, manifest) do
    Map.get(final_report, "verification_summary") || proof_status_summary(manifest, list_field(final_report, "gates_run"))
  end

  defp outputs_section(manifest, archive_path) do
    artifacts = Map.get(manifest, "artifacts", [])
    repo = Map.get(manifest, "repo", %{})

    %{
      "branch" => Map.get(repo, "base_branch"),
      "pr" => pr_output(manifest),
      "patch" => artifact_path(artifacts, "patch"),
      "archive" => archive_path,
      "run_ledger_manifest" => "manifest.json",
      "agent_events" => artifact_path(artifacts, "agent_events"),
      "export_bundle" => artifact_path(artifacts, "export_bundle")
    }
  end

  defp pr_output(manifest) do
    manifest
    |> Map.get("agent", %{})
    |> Map.get("pr")
  end

  defp archive_output(manifest) do
    path = artifact_path(Map.get(manifest, "artifacts", []), "archive")

    cond do
      is_nil(path) -> {nil, false}
      absolute_path?(path) -> {nil, true}
      true -> {path, false}
    end
  end

  defp absolute_path?(path) when is_binary(path), do: Path.type(path) == :absolute

  defp proof_section(ledger, manifest, final_report) do
    final_report_gates = list_field(final_report, "gates_run")

    %{
      "status" => proof_status(manifest, final_report_gates),
      "requirements" => proof_requirements(manifest),
      "gate_results" => gate_results(ledger, manifest, final_report_gates),
      "review" => review_section(manifest)
    }
  end

  defp proof_requirements(manifest) do
    manifest
    |> get_in(["process_provider", "probe", "proof_requirements"])
    |> case do
      requirements when is_list(requirements) -> requirements
      _other -> []
    end
  end

  defp proof_status(manifest, final_report_gates) do
    statuses = [clean_eval_status(manifest) | Enum.map(final_report_gates, &Map.get(&1, "status"))] |> Enum.reject(&is_nil/1)

    cond do
      Enum.any?(statuses, &(&1 in ["fail", "failed", "timeout", "error"])) -> "fail"
      Enum.any?(statuses, &(&1 in ["pass", "passed", "reused"])) -> "pass"
      true -> "unknown"
    end
  end

  defp proof_status_summary(manifest, final_report_gates), do: "proof_status=#{proof_status(manifest, final_report_gates)}"

  defp clean_eval_status(manifest) do
    manifest
    |> Map.get("clean_eval", %{})
    |> Map.get("status")
  end

  defp gate_results(ledger, manifest, final_report_gates) do
    manifest
    |> Map.get("artifacts", [])
    |> Enum.filter(&(Map.get(&1, "kind") == "gate_results"))
    |> Enum.flat_map(&gate_results_from_artifact(ledger, &1))
    |> then(fn results -> if results == [], do: final_report_gate_results(final_report_gates), else: results end)
  end

  defp gate_results_from_artifact(ledger, %{"path" => path}) when is_binary(path) do
    result_path = Path.join(ledger.run_dir, path)

    case File.read(result_path) do
      {:ok, json} -> decoded_gate_results(json, path)
      {:error, _reason} -> [%{"results_path" => path, "status" => "unknown"}]
    end
  end

  defp gate_results_from_artifact(_ledger, _artifact), do: []

  defp decoded_gate_results(json, path) do
    case Jason.decode(json) do
      {:ok, %{"results" => results}} when is_list(results) -> Enum.map(results, &gate_result_reference(&1, path))
      {:ok, %{"status" => status}} -> [%{"results_path" => path, "status" => status}]
      _other -> [%{"results_path" => path, "status" => "unknown"}]
    end
  end

  defp gate_result_reference(result, path) when is_map(result) do
    %{
      "name" => Map.get(result, "name"),
      "status" => Map.get(result, "status"),
      "results_path" => path,
      "stdout_path" => Map.get(result, "stdout_path"),
      "stderr_path" => Map.get(result, "stderr_path")
    }
    |> drop_nil_values()
  end

  defp gate_result_reference(_result, path), do: %{"results_path" => path, "status" => "unknown"}

  defp final_report_gate_results(gates) do
    Enum.map(gates, fn
      gate when is_map(gate) ->
        gate
        |> Map.take(["name", "status"])
        |> Map.put_new("results_path", nil)

      _other ->
        %{"results_path" => nil, "status" => "unknown"}
    end)
  end

  defp review_section(manifest) do
    %{
      "clean_eval" => Map.get(manifest, "clean_eval"),
      "final_report" => Map.get(manifest, "final_report")
    }
    |> drop_nil_values()
  end

  defp interrupts_section(ledger, manifest) do
    checkpoint_payloads(ledger, manifest, "interrupt_created")
    |> case do
      [] -> maybe_list(Map.get(manifest, "interrupt"))
      interrupts -> interrupts
    end
  end

  defp human_decisions_section(ledger, manifest) do
    checkpoint_payloads(ledger, manifest, "action_policy_decision")
  end

  defp checkpoint_payloads(ledger, manifest, kind) do
    manifest
    |> Map.get("checkpoints", [])
    |> Enum.filter(&(Map.get(&1, "kind") == kind))
    |> Enum.flat_map(&checkpoint_payload(ledger, &1))
  end

  defp checkpoint_payload(ledger, %{"path" => path}) when is_binary(path) do
    checkpoint_path = Path.join(ledger.run_dir, path)

    case File.read(checkpoint_path) do
      {:ok, json} -> decoded_checkpoint_payload(json)
      {:error, _reason} -> []
    end
  end

  defp decoded_checkpoint_payload(json) do
    case Jason.decode(json) do
      {:ok, %{"payload" => payload}} when is_map(payload) -> [payload]
      _other -> []
    end
  end

  defp redaction_section do
    %{
      "policy" => "rondo-delivery-artifact-v0-default",
      "raw_logs_embedded" => false,
      "secret_fields_redacted" => true,
      "content_fields_summarized" => true,
      "notes" => "Raw logs, prompts, and diffs are linked by artifact path rather than embedded."
    }
  end

  defp portability_section(manifest, archive_requires_local?) do
    %{
      "path_base" => "run_dir",
      "uses_relative_paths" => true,
      "requires_local_workspace" => archive_requires_local?,
      "external_links" => external_links(manifest),
      "bundle_notes" => "Include artifacts/delivery-artifact.json plus referenced relative artifact paths when creating a handoff bundle."
    }
  end

  defp external_links(manifest) do
    issue = Map.get(manifest, "issue", %{})
    pr = manifest |> Map.get("agent", %{}) |> Map.get("pr")

    [Map.get(issue, "url"), pr_url(pr)]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp pr_url(%{"url" => url}), do: url
  defp pr_url(_pr), do: nil

  defp final_report(ledger, manifest) do
    case get_in(manifest, ["final_report", "path"]) do
      path when is_binary(path) -> read_json_map(Path.join(ledger.run_dir, path))
      _other -> %{}
    end
  end

  defp read_json_map(path) do
    with {:ok, json} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(json) do
      decoded
    else
      _other -> %{}
    end
  end

  defp latest_manifest(ledger) do
    case read_json_map(ledger.manifest_path) do
      manifest when map_size(manifest) > 0 -> manifest
      _empty -> ledger.manifest
    end
  end

  defp artifact_path(artifacts, kind) when is_list(artifacts) do
    artifacts
    |> Enum.find(fn artifact -> Map.get(artifact, "kind") == kind end)
    |> case do
      %{"path" => path} -> path
      _other -> nil
    end
  end

  defp list_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_list(value) -> value
      _other -> []
    end
  end

  defp maybe_list(value) when is_map(value), do: [value]
  defp maybe_list(_value), do: []

  defp sanitize_value(value) when is_binary(value) do
    value
    |> Redaction.redact()
    |> truncate_string()
  end

  defp sanitize_value(value) when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value), do: value
  defp sanitize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_value(value) when is_list(value), do: Enum.map(value, &sanitize_value/1)

  defp sanitize_value(value) when is_map(value) do
    value
    |> Map.new(fn {key, nested_value} ->
      key = to_string(key)

      if secret_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize_value(nested_value)}
      end
    end)
  end

  defp sanitize_value(value), do: value |> inspect() |> truncate_string()

  defp secret_key?("secret_fields_redacted"), do: false
  defp secret_key?(key), do: Regex.match?(@secret_key_pattern, key)

  defp truncate_string(value) do
    if byte_size(value) <= @max_string_bytes do
      value
    else
      binary_part(value, 0, @max_string_bytes) <> "... (truncated)"
    end
  end

  defp drop_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
