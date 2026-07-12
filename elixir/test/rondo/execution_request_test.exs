defmodule Rondo.ExecutionRequestTest do
  use Rondo.TestSupport, async: true

  alias Rondo.Beislid.ExportValidator.Error
  alias Rondo.ExecutionRequest
  alias Rondo.Linear.Issue

  test "loads a valid rondo execution request manifest" do
    path =
      manifest_path("valid-request", %{
        schema: "rondo-execution-request-v1",
        slice_id: "slice-123",
        parent_contract: %{id: "plan-1", source: "beislid"},
        repo: %{base_ref: "main"},
        prompt: "Implement the approved slice.",
        boundaries: ["Do not touch billing."],
        dependencies: [],
        proof_requirements: ["mix test"],
        allowed_actions: %{run_mode: "supervised-auto"},
        process_provider: %{name: "pi"},
        memory_provider: %{name: "memento"},
        output_expectations: %{final_report: true},
        runner_extensions: %{action_policy: %{policy_file: "policy.json"}},
        model_routing_hints: %{initial: %{skill: "kickoff", tier: "heavy"}}
      })

    assert {:ok, request} = ExecutionRequest.load(path)
    assert %Issue{} = request.issue
    assert request.issue.id == "slice-123"
    assert request.issue.identifier == "slice-123"
    assert request.issue.title == "Execution request slice-123"
    assert request.issue.state == "In Progress"
    assert request.issue.description =~ "Implement the approved slice."
    assert request.issue.description =~ "Do not touch billing."
    assert request.issue.description =~ "mix test"

    assert request.source_contract.schema == "rondo-execution-request-v1"
    assert request.source_contract.slice_id == "slice-123"
    assert request.source_contract.path == Path.expand(path)
    assert byte_size(request.source_contract.sha256) == 64
    assert request.source_contract.parent_contract == %{"id" => "plan-1", "source" => "beislid"}
    assert request.source_contract.repo == %{"base_ref" => "main"}
    assert request.source_contract.allowed_actions == %{"run_mode" => "supervised-auto"}
    assert request.source_contract.process_provider == %{"name" => "pi"}
    assert request.source_contract.memory_provider == %{"name" => "memento"}
    assert request.source_contract.output_expectations == %{"final_report" => true}
    assert request.source_contract.runner_extensions == %{"action_policy" => %{"policy_file" => "policy.json"}}
    assert request.source_contract.model_routing_hints == %{"initial" => %{"skill" => "kickoff", "tier" => "heavy"}}
  end

  test "loads approved-slice-v1 with body alias" do
    path =
      manifest_path("approved-slice", %{
        schema: "approved-slice-v1",
        slice_id: "slice-body",
        body: "Use the body field."
      })

    assert {:ok, request} = ExecutionRequest.load(path)
    assert request.issue.description =~ "Use the body field."
    assert request.source_contract.schema == "approved-slice-v1"
  end

  test "loads Beislið approved-slice exports with structured C3 sections" do
    path = Path.expand("../fixtures/execution_requests/approved_slice_structured_c3.json", __DIR__)

    assert {:ok, request} = ExecutionRequest.load(path)
    assert request.issue.id == "bei-131-normalizer-conformance"
    assert request.source_contract.schema == "approved-slice-v1"

    assert request.source_contract.boundaries["include"] == [
             "scripts/workflow_normalizer.py",
             "scripts/test_workflow_normalizer.py",
             "scripts/run_conformance.py",
             "tests/conformance/**",
             "docs/parser-conformance.md",
             ".beislid/workflow-md-format.md",
             ".github/workflows/validate.yml"
           ]

    assert request.issue.description =~ "## Boundaries\n\n```json\n"
    assert request.issue.description =~ "scripts/workflow_normalizer.py"
    assert request.issue.description =~ "## Proof requirements\n\n```json\n"
    assert request.issue.description =~ "bei-131-gates"
    assert request.issue.description =~ "proof-requirement-v1"
  end

  describe "prepare_core_submission/3" do
    test "accepts the committed producer golden and preserves exact evidence" do
      manifest_path =
        Path.expand(
          "../../../.beislid/exports/ron-136-ron-137-p0-integrity/slices/ron-136-claude-adapter-parity.json",
          __DIR__
        )

      digest = manifest_path |> File.read!() |> sha256()

      assert {:ok, prepared} =
               ExecutionRequest.prepare_core_submission(
                 manifest_path,
                 digest,
                 "repo:producer-golden"
               )

      assert prepared.source_contract.schema == "approved-slice-v1"
      assert prepared.manifest_evidence.bytes == File.read!(manifest_path)
      assert prepared.approval_evidence.version == 2
      assert prepared.approval_evidence.approved_at == "2026-07-03T10:06:41Z"
      assert prepared.approval_evidence.verdict == "approve"
    end

    test "returns a canonical approved intake with the caller repo id and verified digest" do
      export = approved_export("slice-123")

      assert {:ok, prepared} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo:opaque/123"
               )

      identity = execution_identity("repo:opaque/123", export.digest)
      expected_issue_id = "execution-request:#{identity}"
      expected_identifier = "execution-request-#{identity}"

      assert %Issue{
               id: ^expected_issue_id,
               identifier: ^expected_identifier,
               title: "Execution request slice-123"
             } = prepared.issue

      assert prepared.repo_id == "repo:opaque/123"
      assert prepared.policy_file == nil
      assert prepared.source_contract.schema == "approved-slice-v1"
      assert prepared.source_contract.slice_id == "slice-123"
      assert prepared.source_contract.path == export.canonical_manifest_path
      assert prepared.source_contract.sha256 == export.digest
      assert prepared.manifest_evidence.source_path == export.canonical_manifest_path
      assert prepared.manifest_evidence.sha256 == export.digest
      assert prepared.manifest_evidence.bytes == File.read!(export.manifest_path)
      assert prepared.approval_evidence.source_path == export.bundle_path
      assert prepared.approval_evidence.sha256 == sha256(File.read!(export.bundle_path))
      assert prepared.approval_evidence.bytes == File.read!(export.bundle_path)
      assert prepared.approval_evidence.kind == "approved-slice-plan-export-v0"
      assert prepared.approval_evidence.version == 1
      assert prepared.approval_evidence.status == "approved"
      assert prepared.approval_evidence.approved_at == "2026-07-09T12:00:00Z"
      assert prepared.approval_evidence.approved_by == "Rondo Test"
      assert prepared.approval_evidence.slice_id == "slice-123"
      assert prepared.approval_evidence.verdict == "approve"

      assert {:ok, other_repo} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo:opaque/other"
               )

      refute other_repo.issue.id == prepared.issue.id
      refute other_repo.issue.identifier == prepared.issue.identifier

      changed_export =
        approved_export("slice-123",
          manifest: %{prompt: "Implement the same display slice with different approved bytes."}
        )

      assert {:ok, changed_manifest} =
               ExecutionRequest.prepare_core_submission(
                 changed_export.manifest_path,
                 changed_export.digest,
                 "repo:opaque/123"
               )

      refute changed_manifest.issue.id == prepared.issue.id
      refute changed_manifest.issue.identifier == prepared.issue.identifier
      assert changed_manifest.issue.title == prepared.issue.title
    end

    test "namespaces Plot-scoped submissions without changing legacy identities" do
      export = approved_export("slice-plot-namespace")

      assert {:ok, legacy} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo:plot"
               )

      assert {:ok, first_plot} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo:plot",
                 "OLI-52"
               )

      assert {:ok, second_plot} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo:plot",
                 "OLI-foreign"
               )

      assert legacy.plot_id == nil
      assert first_plot.plot_id == "OLI-52"
      assert second_plot.plot_id == "OLI-foreign"
      assert legacy.issue.id == "execution-request:#{execution_identity("repo:plot", export.digest)}"
      refute first_plot.issue.id == legacy.issue.id
      refute second_plot.issue.id == first_plot.issue.id
    end

    test "requires an exact bounded Plot id when supplied" do
      export = approved_export("slice-plot-validation")

      for plot_id <- [
            "",
            " padded",
            "padded ",
            "control\ncharacter",
            "control\0character",
            String.duplicate("p", 513)
          ] do
        assert {:error, :core_intake_invalid_plot_id} =
                 ExecutionRequest.prepare_core_submission(
                   export.manifest_path,
                   export.digest,
                   "repo-plot",
                   plot_id
                 )
      end
    end

    test "rejects path-like slice ids before they become internal path components" do
      export = approved_export("..")

      assert {:error, %Error{code: :unsafe_export_path}} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-path-safety"
               )
    end

    test "requires a lowercase SHA-256 and an exact digest match" do
      export = approved_export("slice-digest")

      assert {:error, :core_intake_invalid_expected_sha256} =
               ExecutionRequest.prepare_core_submission(export.manifest_path, "not-a-digest", "repo-1")

      wrong_digest = String.duplicate("0", 64)

      assert {:error, {:core_intake_manifest_sha256_mismatch, ^wrong_digest, actual_digest}} =
               ExecutionRequest.prepare_core_submission(export.manifest_path, wrong_digest, "repo-1")

      assert actual_digest == export.digest
    end

    test "requires a bounded exact opaque repo id without normalizing it" do
      export = approved_export("slice-repo")

      for repo_id <- [
            nil,
            "",
            "   ",
            " padded",
            "padded ",
            "control\ncharacter",
            "control\0character",
            String.duplicate("r", 513)
          ] do
        assert {:error, :core_intake_invalid_repo_id} =
                 ExecutionRequest.prepare_core_submission(export.manifest_path, export.digest, repo_id)
      end

      assert {:ok, prepared} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo id preserved/opaquely"
               )

      assert prepared.repo_id == "repo id preserved/opaquely"

      assert {:ok, max_length} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 String.duplicate("r", 512)
               )

      assert byte_size(max_length.repo_id) == 512
    end

    test "resolves the manifest action policy relative to the canonical manifest" do
      export =
        approved_export("slice-policy",
          manifest: %{
            runner_extensions: %{
              action_policy: %{policy_file: "policies/action-policy.json"}
            }
          }
        )

      policy_file = Path.join(Path.dirname(export.manifest_path), "policies/action-policy.json")
      File.mkdir_p!(Path.dirname(policy_file))
      File.write!(policy_file, Jason.encode!(%{"version" => "beislid.action-policy/v1"}))

      assert {:ok, prepared} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      assert prepared.policy_file ==
               Path.expand(
                 "policies/action-policy.json",
                 Path.dirname(export.canonical_manifest_path)
               )
    end

    test "preserves RunOnce action-policy validation errors" do
      invalid_extensions =
        approved_export("slice-extensions", manifest: %{runner_extensions: "invalid"})

      assert {:error, {:invalid_manifest_runner_extensions, "invalid"}} =
               ExecutionRequest.prepare_core_submission(
                 invalid_extensions.manifest_path,
                 invalid_extensions.digest,
                 "repo-1"
               )

      invalid_policy_file =
        approved_export("slice-policy-value",
          manifest: %{runner_extensions: %{action_policy: %{policy_file: 123}}}
        )

      assert {:error, {:invalid_manifest_policy_file, 123}} =
               ExecutionRequest.prepare_core_submission(
                 invalid_policy_file.manifest_path,
                 invalid_policy_file.digest,
                 "repo-1"
               )

      missing_policy_file =
        approved_export("slice-policy-missing",
          manifest: %{
            runner_extensions: %{action_policy: %{policy_file: "missing-policy.json"}}
          }
        )

      expected_missing =
        Path.expand("missing-policy.json", Path.dirname(missing_policy_file.canonical_manifest_path))

      assert {:error, {:manifest_policy_file_unreadable, ^expected_missing}} =
               ExecutionRequest.prepare_core_submission(
                 missing_policy_file.manifest_path,
                 missing_policy_file.digest,
                 "repo-1"
               )
    end

    test "accepts both producer slice schema literals" do
      export = approved_export("slice-schema", manifest: %{schema: "rondo-execution-request-v1"})

      assert {:ok, prepared} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      assert prepared.source_contract.schema == "rondo-execution-request-v1"
    end

    test "returns a stable manifest JSON error without exposing manifest contents" do
      export = approved_export("slice-invalid-json")
      invalid_json = "{not json SECRET-MANIFEST-BODY"
      File.write!(export.manifest_path, invalid_json)
      digest = sha256(invalid_json)

      assert {:error, %Error{code: :invalid_export} = validation_error} =
               error =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 digest,
                 "repo-1"
               )

      assert %{path: "selected-slice.json", rule: :invalid_json} in validation_error.violations

      refute inspect(error) =~ "SECRET-MANIFEST-BODY"
    end

    test "rejects missing, non-regular, and symlink manifest paths" do
      export = approved_export("slice-path")
      missing = Path.join(Path.dirname(export.manifest_path), "missing.json")

      assert {:error, %Error{code: :unsafe_export_path}} =
               ExecutionRequest.prepare_core_submission(
                 "relative/slices/slice-path.json",
                 export.digest,
                 "repo-1"
               )

      assert {:error, %Error{code: :unsafe_export_path}} =
               ExecutionRequest.prepare_core_submission(missing, export.digest, "repo-1")

      assert {:error, %Error{code: :unsafe_export_path}} =
               ExecutionRequest.prepare_core_submission(
                 Path.dirname(export.manifest_path),
                 export.digest,
                 "repo-1"
               )

      symlink = Path.join(Path.dirname(export.manifest_path), "symlink.json")
      File.ln_s!(export.manifest_path, symlink)

      assert {:error, %Error{code: :unsafe_export_path}} =
               ExecutionRequest.prepare_core_submission(symlink, export.digest, "repo-1")
    end

    test "rejects manifest paths inconsistent with the approved export layout" do
      export = approved_export("slice-layout", filename: "other.json")

      assert {:error, %Error{code: :invalid_export}} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )
    end

    test "requires a regular nonsymlinked sibling bundle.json" do
      export = approved_export("slice-bundle-path")
      File.rm!(export.bundle_path)

      assert {:error, %Error{code: :unsafe_export_path}} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      real_bundle = Path.join(export.bundle_dir, "real-bundle.json")
      File.write!(real_bundle, Jason.encode!(approved_bundle("slice-bundle-path")))
      File.ln_s!(real_bundle, export.bundle_path)

      assert {:error, %Error{code: :unsafe_export_path}} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )
    end

    test "requires a parseable approved-slice-plan-export-v0 bundle" do
      export = approved_export("slice-bundle-shape")
      File.write!(export.bundle_path, "{not json SECRET-MANIFEST-BODY")

      assert {:error, %Error{code: :invalid_export} = validation_error} =
               error =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      assert %{path: "bundle.json", rule: :invalid_json} in validation_error.violations

      refute inspect(error) =~ "SECRET-MANIFEST-BODY"

      write_bundle(export, %{kind: "other-kind"})

      assert {:error, %Error{code: :invalid_export}} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      write_bundle(export, %{status: "draft"})

      assert {:error, %Error{code: :unapproved_export}} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      write_bundle(export, %{version: 0})

      assert {:error, %Error{code: :invalid_export}} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      write_bundle(export, %{approval: %{"approved_by" => " "}})

      assert {:error, %Error{code: :unapproved_export}} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )
    end

    test "requires the slice to be listed and honors optional verdict evidence" do
      export = approved_export("slice-verdict")
      write_bundle(export, %{children: []})

      assert {:error, %Error{code: :invalid_export}} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      write_bundle(export, %{approval: %{"verdicts" => %{"slice-verdict" => "reject"}}})

      assert {:ok, rejected_verdict_metadata} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      assert rejected_verdict_metadata.approval_evidence.verdict == "reject"

      write_bundle(export, %{approval: %{"verdicts" => %{}}})

      assert {:ok, missing_selected_verdict} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      assert missing_selected_verdict.approval_evidence.verdict == nil

      write_bundle(export, %{
        approval: %{
          "approved_at" => "2026-07-09T12:00:00Z",
          "approved_by" => "Rondo Test",
          "verdicts" => nil
        }
      })

      assert {:ok, nil_verdict_map} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      assert nil_verdict_map.approval_evidence.verdict == nil

      bundle = approved_bundle(export.slice_id)
      bundle = put_in(bundle, ["approval"], Map.delete(bundle["approval"], "verdicts"))
      File.write!(export.bundle_path, Jason.encode!(bundle))

      assert {:ok, prepared} =
               ExecutionRequest.prepare_core_submission(
                 export.manifest_path,
                 export.digest,
                 "repo-1"
               )

      assert prepared.approval_evidence.verdict == nil
    end
  end

  test "rejects invalid JSON" do
    path = raw_manifest_path("invalid-json", "{not json")

    assert {:error, {:invalid_execution_request_json, message}} = ExecutionRequest.load(path)
    assert message =~ "unexpected byte"
  end

  test "returns path-aware read errors" do
    path = Path.join(System.tmp_dir!(), "missing-request-#{System.unique_integer([:positive])}.json")

    assert {:error, {:execution_request_read_failed, expanded_path, :enoent}} = ExecutionRequest.load(path)
    assert expanded_path == Path.expand(path)
  end

  test "rejects unsupported schemas" do
    path = manifest_path("unknown-schema", %{schema: "unknown-v1", slice_id: "slice-123", prompt: "Do it."})

    assert {:error, {:unsupported_execution_request_schema, "unknown-v1"}} = ExecutionRequest.load(path)
  end

  test "normalizes optional string/list sections" do
    list_path =
      manifest_path("list-sections", %{
        schema: "rondo-execution-request-v1",
        slice_id: "slice-list",
        prompt: "Do it.",
        boundaries: "Only docs.",
        output_expectations: ["final report"],
        memory_provider: [%{name: "memento"}]
      })

    assert {:ok, list_request} = ExecutionRequest.load(list_path)
    assert list_request.issue.description =~ "Only docs."
    assert list_request.issue.description =~ "final report"
    assert list_request.source_contract.memory_provider == [%{"name" => "memento"}]

    string_path =
      manifest_path("string-output", %{
        schema: "rondo-execution-request-v1",
        slice_id: "slice-string",
        prompt: "Do it.",
        output_expectations: "Return a summary."
      })

    assert {:ok, string_request} = ExecutionRequest.load(string_path)
    assert string_request.issue.description =~ "Return a summary."
  end

  test "rejects invalid optional section scalars" do
    assert {:error, {:invalid_execution_request_field, "boundaries"}} =
             "invalid-boundaries"
             |> manifest_path(%{
               schema: "rondo-execution-request-v1",
               slice_id: "slice-123",
               prompt: "Do it.",
               boundaries: 123
             })
             |> ExecutionRequest.load()

    assert {:error, {:invalid_execution_request_field, "dependencies"}} =
             "invalid-dependencies"
             |> manifest_path(%{
               schema: "rondo-execution-request-v1",
               slice_id: "slice-123",
               prompt: "Do it.",
               dependencies: 123
             })
             |> ExecutionRequest.load()
  end

  test "rejects missing required fields" do
    assert {:error, {:missing_execution_request_field, "slice_id"}} =
             "missing-slice"
             |> manifest_path(%{schema: "rondo-execution-request-v1", prompt: "Do it."})
             |> ExecutionRequest.load()

    assert {:error, {:missing_execution_request_field, "prompt"}} =
             "missing-prompt"
             |> manifest_path(%{schema: "rondo-execution-request-v1", slice_id: "slice-123"})
             |> ExecutionRequest.load()
  end

  test "rejects invalid path and manifest shapes" do
    assert {:error, {:invalid_execution_request_path, 123}} = ExecutionRequest.load(123)

    assert {:error, :invalid_execution_request_manifest} =
             "invalid-shape"
             |> raw_manifest_path("[]")
             |> ExecutionRequest.load()
  end

  defp manifest_path(name, payload) do
    raw_manifest_path(name, Jason.encode!(payload))
  end

  defp raw_manifest_path(name, content) do
    {:ok, canonical_tmp} = Rondo.PathSafety.canonicalize(System.tmp_dir!())

    dir =
      Path.join(
        canonical_tmp,
        "rondo-execution-request-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}.json")
    File.write!(path, content)
    path
  end

  defp approved_export(slice_id, opts \\ []) do
    {:ok, canonical_tmp} = Rondo.PathSafety.canonicalize(System.tmp_dir!())

    bundle_dir =
      Path.join(
        canonical_tmp,
        "rondo-approved-export-#{slice_id}-#{System.unique_integer([:positive])}"
      )

    slices_dir = Path.join(bundle_dir, "slices")
    File.mkdir_p!(slices_dir)

    manifest =
      Map.merge(
        %{
          schema: "approved-slice-v1",
          slice_id: slice_id,
          prompt: "Implement #{slice_id}.",
          repo: %{
            url: "https://example.test/rondo.git",
            base_ref: "main",
            base_sha: String.duplicate("a", 40)
          }
        },
        Keyword.get(opts, :manifest, %{})
      )

    manifest_json = Jason.encode!(manifest)
    filename = Keyword.get(opts, :filename, "#{slice_id}.json")
    manifest_path = Path.join(slices_dir, filename)
    File.write!(manifest_path, manifest_json)
    File.write!(Path.join(slices_dir, "#{slice_id}.md"), "# #{slice_id}\n")

    bundle_path = Path.join(bundle_dir, "bundle.json")
    File.write!(bundle_path, Jason.encode!(approved_bundle(slice_id)))

    {:ok, canonical_manifest_path} = Rondo.PathSafety.canonicalize(manifest_path)
    canonical_bundle_dir = canonical_manifest_path |> Path.dirname() |> Path.dirname()

    %{
      bundle_dir: canonical_bundle_dir,
      bundle_path: Path.join(canonical_bundle_dir, "bundle.json"),
      manifest_path: manifest_path,
      canonical_manifest_path: canonical_manifest_path,
      digest: sha256(manifest_json),
      slice_id: slice_id
    }
  end

  defp approved_bundle(slice_id) do
    %{
      "kind" => "approved-slice-plan-export-v0",
      "version" => 1,
      "status" => "approved",
      "generated_from" => "test",
      "source_work_contract" => "test",
      "slice_plan" => %{},
      "children" => [%{"id" => slice_id}],
      "dependency_graph" => %{slice_id => []},
      "proof_requirements" => [],
      "guides_and_gates" => %{},
      "approval" => %{
        "approved_at" => "2026-07-09T12:00:00Z",
        "approved_by" => "Rondo Test",
        "verdicts" => %{slice_id => "approve"}
      },
      "runner_extensions" => %{},
      "validation" => %{
        "schema_version" => "approved-slice-plan-export-v0",
        "rubric_version" => "afk-rubric-v1"
      },
      "ownership" => %{},
      "supersedes" => nil
    }
  end

  defp write_bundle(export, overrides) do
    bundle =
      Map.merge(
        approved_bundle(export.slice_id),
        stringify_keys(overrides),
        fn
          "approval", existing, update when is_map(existing) and is_map(update) ->
            Map.merge(existing, update)

          _key, _existing, update ->
            update
        end
      )

    File.write!(export.bundle_path, Jason.encode!(bundle))
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp sha256(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end

  defp execution_identity(repo_id, digest), do: sha256(repo_id <> <<0>> <> digest)
end
