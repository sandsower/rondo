defmodule Rondo.ExecutionRequestTest do
  use Rondo.TestSupport, async: true

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
        output_expectations: %{final_report: true}
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

  test "rejects invalid JSON" do
    path = raw_manifest_path("invalid-json", "{not json")

    assert {:error, {:invalid_execution_request_json, message}} = ExecutionRequest.load(path)
    assert message =~ "unexpected byte"
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
    dir = Path.join(System.tmp_dir!(), "rondo-execution-request-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}.json")
    File.write!(path, content)
    path
  end
end
