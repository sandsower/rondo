defmodule Rondo.Beislid.ExportValidatorTest do
  use ExUnit.Case, async: true

  alias Rondo.Beislid.ExportValidator
  alias Rondo.Beislid.ExportValidator.Error
  alias Rondo.Beislid.SchemaSubset

  @bundle_id "ron-136-ron-137-p0-integrity"
  @selected_id "ron-136-claude-adapter-parity"
  @other_id "ron-137-config-validation"
  @golden Path.expand("../../../../.beislid/exports/#{@bundle_id}", __DIR__)

  test "accepts the producer-valid committed export and returns exact approval evidence" do
    manifest = Path.join(@golden, "slices/#{@selected_id}.json")

    assert {:ok, evidence} = ExportValidator.validate(manifest)
    assert evidence.slice_id == @selected_id
    assert evidence.approval.selected_slice == @selected_id
    assert evidence.approval.bundle_kind == "approved-slice-plan-export-v0"
    assert evidence.approval.bundle_status == "approved"
    assert evidence.approval.bundle_version == 2
    assert evidence.approval.verdict == "approve"
    assert evidence.approval.approved_at == "2026-07-03T10:06:41Z"
    assert String.starts_with?(evidence.approval.approved_by, "Vic Valenzuela")

    assert evidence.bundle.bytes == File.read!(Path.join(@golden, "bundle.json"))
    assert evidence.manifest.bytes == File.read!(manifest)
    assert evidence.bundle.sha256 == sha256(evidence.bundle.bytes)
    assert evidence.manifest.sha256 == sha256(evidence.manifest.bytes)
    assert :ok = ExportValidator.verify_unchanged(evidence)
  end

  test "accepts both producer slice schema literals" do
    bundle_dir = copy_golden("alternate-schema")
    manifest = selected_manifest(bundle_dir)
    update_json(manifest, &Map.put(&1, "schema", "rondo-execution-request-v1"))

    assert {:ok, %{manifest: %{bytes: bytes}}} = ExportValidator.validate(manifest)
    assert %{"schema" => "rondo-execution-request-v1"} = Jason.decode!(bytes)
  end

  test "approval verdicts are optional producer metadata, not an admission requirement" do
    bundle_dir = copy_golden("optional-verdicts")

    update_json(bundle_path(bundle_dir), fn bundle ->
      update_in(bundle, ["approval"], &Map.delete(&1, "verdicts"))
    end)

    assert {:ok, %{approval: %{verdict: nil}}} =
             ExportValidator.validate(selected_manifest(bundle_dir))
  end

  test "rejects every required bundle field and nested approval identity field" do
    fields =
      ~w(kind version generated_from source_work_contract slice_plan children dependency_graph proof_requirements guides_and_gates runner_extensions validation ownership supersedes)

    Enum.each(fields, fn field ->
      bundle_dir = copy_golden("required-bundle-#{field}")
      update_json(bundle_path(bundle_dir), &Map.delete(&1, field))
      assert_invalid(selected_manifest(bundle_dir), "required bundle field #{field}")
    end)

    Enum.each(~w(status approval), fn field ->
      bundle_dir = copy_golden("required-approval-bundle-#{field}")
      update_json(bundle_path(bundle_dir), &Map.delete(&1, field))

      assert_unapproved(
        selected_manifest(bundle_dir),
        "required approval bundle field #{field}"
      )
    end)

    Enum.each(~w(approved_at approved_by), fn field ->
      bundle_dir = copy_golden("required-approval-#{field}")

      update_json(bundle_path(bundle_dir), fn bundle ->
        update_in(bundle, ["approval"], &Map.delete(&1, field))
      end)

      assert_unapproved(selected_manifest(bundle_dir), "required approval field #{field}")
    end)

    Enum.each(~w(schema_version rubric_version), fn field ->
      bundle_dir = copy_golden("required-validation-#{field}")

      update_json(bundle_path(bundle_dir), fn bundle ->
        update_in(bundle, ["validation"], &Map.delete(&1, field))
      end)

      assert_invalid(selected_manifest(bundle_dir), "required validation field #{field}")
    end)
  end

  test "rejects every required slice and repository field" do
    Enum.each(~w(schema slice_id repo), fn field ->
      bundle_dir = copy_golden("required-slice-#{field}")
      update_json(selected_manifest(bundle_dir), &Map.delete(&1, field))
      assert_invalid(selected_manifest(bundle_dir), "required slice field #{field}")
    end)

    Enum.each(~w(url base_ref base_sha), fn field ->
      bundle_dir = copy_golden("required-repo-#{field}")

      update_json(selected_manifest(bundle_dir), fn manifest ->
        update_in(manifest, ["repo"], &Map.delete(&1, field))
      end)

      assert_invalid(selected_manifest(bundle_dir), "required repo field #{field}")
    end)

    Enum.each(~w(tier mode candidates), fn field ->
      bundle_dir = copy_golden("required-model-routing-#{field}")

      update_json(selected_manifest(bundle_dir), fn manifest ->
        update_in(manifest, ["runner_extensions", "model_routing"], &Map.delete(&1, field))
      end)

      assert_invalid(selected_manifest(bundle_dir), "required model-routing field #{field}")
    end)

    Enum.each(~w(boundary tier mode), fn field ->
      bundle_dir = copy_golden("required-routing-rule-#{field}")

      update_json(selected_manifest(bundle_dir), fn manifest ->
        update_in(
          manifest,
          ["runner_extensions", "model_routing", "routing", Access.at(0)],
          &Map.delete(&1, field)
        )
      end)

      assert_invalid(selected_manifest(bundle_dir), "required routing-rule field #{field}")
    end)

    Enum.each(~w(id command), fn field ->
      bundle_dir = copy_golden("required-command-proof-#{field}")

      update_json(selected_manifest(bundle_dir), fn manifest ->
        Map.put(manifest, "command_proofs", [Map.delete(%{"id" => "proof", "command" => "true"}, field)])
      end)

      assert_invalid(selected_manifest(bundle_dir), "required command-proof field #{field}")
    end)
  end

  test "rejects a child reference without its required id" do
    bundle_dir = copy_golden("required-child-id")

    update_json(bundle_path(bundle_dir), fn bundle ->
      update_in(bundle, ["children", Access.at(1)], &Map.delete(&1, "id"))
    end)

    assert_invalid(selected_manifest(bundle_dir), "required child id")
  end

  test "rejects supersedes and child-list semantic mutations" do
    cases = [
      {"v1 with supersedes", fn bundle -> Map.put(bundle, "version", 1) end},
      {"v2 without supersedes", fn bundle -> Map.put(bundle, "supersedes", nil) end},
      {"malformed supersedes", fn bundle -> Map.put(bundle, "supersedes", String.duplicate("A", 64)) end},
      {"empty children", fn bundle -> Map.put(bundle, "children", []) end},
      {"duplicate child", fn bundle -> update_in(bundle, ["children"], &(&1 ++ [hd(&1)])) end},
      {"unsafe child", fn bundle -> put_in(bundle, ["children", Access.at(1), "id"], "../escape") end}
    ]

    Enum.each(cases, fn {label, mutation} ->
      bundle_dir = copy_golden("bundle-semantics-#{slug(label)}")
      update_json(bundle_path(bundle_dir), mutation)
      assert_invalid(selected_manifest(bundle_dir), label)
    end)
  end

  test "rejects dependency graph mutations" do
    cases = [
      {"unknown graph node", fn bundle -> put_in(bundle, ["dependency_graph", "unknown"], []) end},
      {"dependencies not a list", fn bundle -> put_in(bundle, ["dependency_graph", @selected_id], "bad") end},
      {"unknown dependency", fn bundle -> put_in(bundle, ["dependency_graph", @selected_id], ["unknown"]) end},
      {"cycle",
       fn bundle ->
         bundle
         |> put_in(["dependency_graph", @selected_id], [@other_id])
         |> put_in(["dependency_graph", @other_id], [@selected_id])
       end}
    ]

    Enum.each(cases, fn {label, mutation} ->
      bundle_dir = copy_golden("graph-#{slug(label)}")
      update_json(bundle_path(bundle_dir), mutation)
      assert_invalid(selected_manifest(bundle_dir), label)
    end)
  end

  test "rejects parallel group mutations including transitive dependencies" do
    cases = [
      {"groups not lists", fn bundle -> put_in(bundle, ["slice_plan", "parallel_groups"], ["bad"]) end},
      {"nested group member",
       fn bundle ->
         put_in(bundle, ["slice_plan", "parallel_groups"], [[[@selected_id]]])
       end},
      {"unknown group member", fn bundle -> put_in(bundle, ["slice_plan", "parallel_groups"], [["unknown"]]) end},
      {"duplicate group member",
       fn bundle ->
         put_in(bundle, ["slice_plan", "parallel_groups"], [[@selected_id], [@selected_id]])
       end},
      {"dependent group members",
       fn bundle ->
         bundle
         |> put_in(["dependency_graph", @selected_id], [@other_id])
         |> put_in(["slice_plan", "parallel_groups"], [[@selected_id, @other_id]])
       end}
    ]

    Enum.each(cases, fn {label, mutation} ->
      bundle_dir = copy_golden("parallel-#{slug(label)}")
      update_json(bundle_path(bundle_dir), mutation)
      assert_invalid(selected_manifest(bundle_dir), label)
    end)
  end

  test "rejects child-file correspondence and orphan mutations" do
    missing_manifest = copy_golden("missing-manifest")
    File.rm!(Path.join(missing_manifest, "slices/#{@other_id}.json"))
    assert_invalid(selected_manifest(missing_manifest), "missing child manifest")

    missing_summary = copy_golden("missing-summary")
    File.rm!(Path.join(missing_summary, "slices/#{@other_id}.md"))
    assert_invalid(selected_manifest(missing_summary), "missing child summary")

    orphan = copy_golden("orphan")
    File.cp!(selected_manifest(orphan), Path.join(orphan, "slices/orphan.json"))
    assert_invalid(selected_manifest(orphan), "orphan manifest")
  end

  test "rejects slice semantic and model-routing mutations" do
    cases = [
      {"slice id mismatch", fn manifest -> Map.put(manifest, "slice_id", "wrong") end},
      {"no prompt or body", fn manifest -> manifest |> Map.delete("prompt") |> Map.delete("body") end},
      {"empty prompt and body", fn manifest -> manifest |> Map.put("prompt", " ") |> Map.put("body", "") end},
      {"empty candidates", fn manifest -> put_in(manifest, ["runner_extensions", "model_routing", "candidates"], []) end},
      {"empty routing", fn manifest -> put_in(manifest, ["runner_extensions", "model_routing", "routing"], []) end}
    ]

    Enum.each(cases, fn {label, mutation} ->
      bundle_dir = copy_golden("slice-semantics-#{slug(label)}")
      update_json(selected_manifest(bundle_dir), mutation)
      assert_invalid(selected_manifest(bundle_dir), label)
    end)
  end

  test "rejects unsafe selected, bundle, manifest, and summary symlinks" do
    selected_link = copy_golden("selected-symlink")
    manifest = selected_manifest(selected_link)
    real_manifest = manifest <> ".real"
    File.rename!(manifest, real_manifest)
    File.ln_s!(real_manifest, manifest)
    assert_unsafe(manifest, "selected symlink")

    bundle_link = copy_golden("bundle-symlink")
    bundle = bundle_path(bundle_link)
    real_bundle = bundle <> ".real"
    File.rename!(bundle, real_bundle)
    File.ln_s!(real_bundle, bundle)
    assert_unsafe(selected_manifest(bundle_link), "bundle symlink")

    child_link = copy_golden("child-symlink")
    child = Path.join(child_link, "slices/#{@other_id}.json")
    real_child = child <> ".real"
    File.rename!(child, real_child)
    File.ln_s!(real_child, child)
    assert_invalid(selected_manifest(child_link), "child manifest symlink")

    summary_link = copy_golden("summary-symlink")
    summary = Path.join(summary_link, "slices/#{@other_id}.md")
    real_summary = summary <> ".real"
    File.rename!(summary, real_summary)
    File.ln_s!(real_summary, summary)
    assert_invalid(selected_manifest(summary_link), "summary symlink")
  end

  test "requires the selected manifest path itself to be absolute, expanded, and canonical" do
    assert_unsafe(".beislid/exports/#{@bundle_id}/slices/#{@selected_id}.json", "relative path")

    unexpanded = Path.join([@golden, "slices", "..", "slices", @selected_id <> ".json"])
    assert_unsafe(unexpanded, "unexpanded absolute path")
  end

  test "detects exact byte changes before admission and returns sanitized errors" do
    bundle_dir = copy_golden("changed-evidence")
    manifest = selected_manifest(bundle_dir)
    assert {:ok, evidence} = ExportValidator.validate(manifest)

    File.write!(bundle_path(bundle_dir), evidence.bundle.bytes <> "\n")

    assert {:error, %Error{code: :export_changed} = error} =
             ExportValidator.verify_unchanged(evidence)

    rendered = inspect(error)
    refute rendered =~ bundle_dir
    refute rendered =~ "Vic Valenzuela"
    refute rendered =~ "git@github.com"
  end

  test "validation errors do not echo bundle values or filesystem paths" do
    bundle_dir = copy_golden("sanitized-error")
    secret = "secret-slice-value-do-not-echo"

    update_json(bundle_path(bundle_dir), fn bundle ->
      bundle
      |> put_in(["children", Access.at(1), "id"], secret)
      |> put_in(["dependency_graph"], %{secret => ["unknown-secret-dependency"]})
    end)

    assert {:error, %Error{} = error} = ExportValidator.validate(selected_manifest(bundle_dir))
    rendered = inspect(error)
    refute rendered =~ secret
    refute rendered =~ "unknown-secret-dependency"
    refute rendered =~ bundle_dir
  end

  test "vendored schemas use only the pinned producer subset" do
    schemas = [
      {"contracts/beislid/approved-slice-plan-export-v0.schema.json", "eca6c1973eb16aa960fa0ecf0088c61eb1971c260c3c95f12e759e6d73e1a7e7"},
      {"contracts/beislid/execution-envelope-v0.schema.json", "d7aafac1d6b6aa2e1edc97f118eb317c390331da9a0ad61b61b3db57f9dde8c6"}
    ]

    for {relative, expected_sha256} <- schemas do
      schema = SchemaSubset.load!(relative)
      assert SchemaSubset.supported?(schema)
      assert SchemaSubset.unsupported_keywords(schema) == []

      path = :rondo |> :code.priv_dir() |> to_string() |> Path.join(relative)
      assert path |> File.read!() |> sha256() == expected_sha256
    end
  end

  defp assert_invalid(path, label) do
    assert {:error, %Error{code: :invalid_export} = error} = ExportValidator.validate(path), label
    assert error.message == "The export is invalid."
    assert error.violations != []
    refute inspect(error) =~ Path.dirname(Path.dirname(path))
  end

  defp assert_unapproved(path, label) do
    assert {:error, %Error{code: :unapproved_export} = error} = ExportValidator.validate(path), label
    assert error.message == "The export is not approved."
    assert error.violations != []
  end

  defp assert_unsafe(path, label) do
    assert {:error, %Error{code: :unsafe_export_path} = error} = ExportValidator.validate(path), label
    assert error.message == "The export path is unsafe."
    assert error.violations != []
  end

  defp copy_golden(label) do
    {:ok, canonical_tmp} = Rondo.PathSafety.canonicalize(System.tmp_dir!())

    root =
      Path.join(
        canonical_tmp,
        "rondo-export-validator-#{label}-#{System.unique_integer([:positive])}"
      )

    destination = Path.join(root, @bundle_id)
    File.mkdir_p!(root)
    File.cp_r!(@golden, destination)
    on_exit(fn -> File.rm_rf!(root) end)
    destination
  end

  defp update_json(path, mutation) do
    payload = path |> File.read!() |> Jason.decode!() |> mutation.()
    File.write!(path, Jason.encode_to_iodata!(payload, pretty: true))
  end

  defp selected_manifest(bundle_dir), do: Path.join(bundle_dir, "slices/#{@selected_id}.json")
  defp bundle_path(bundle_dir), do: Path.join(bundle_dir, "bundle.json")
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp slug(label), do: String.replace(label, ~r/[^a-z0-9]+/, "-")
end
