defmodule Rondo.CoreContractAssetsTest do
  use ExUnit.Case, async: true

  @asset_root Path.expand("../../../docs/proposed-teotl-conformance/execution", __DIR__)

  test "published event contract matches the paged HTTP response and opaque evidence policy" do
    schema = decode_json!("schemas/rondo-core-run-events-v1.schema.json")

    assert schema["additionalProperties"] == true

    assert MapSet.new(schema["required"]) ==
             MapSet.new(~w(surface repo_id run_id events next_event_cursor has_more))

    properties = schema["properties"]
    assert properties["surface"]["const"] == "rondo.core/v1"
    assert properties["repo_id"]["maxLength"] == 512
    assert properties["run_id"]["maxLength"] == 512
    assert properties["has_more"]["type"] == "boolean"
    assert get_in(schema, ["$defs", "boundedDiagnostic", "additionalProperties"]) == true

    assert schema |> get_in(["$defs", "event", "oneOf"]) |> List.last() == %{
             "$ref" => "#/$defs/boundedDiagnostic"
           }

    assert get_in(schema, ["$defs", "runEvidenceRecorded", "properties", "uri", "pattern"]) == "^rondo-run://"

    for fixture <- ~w(fixtures/run-events-archived-replay.json fixtures/run-events-resume.json) do
      response = decode_json!(fixture)

      assert response["surface"] == "rondo.core/v1"
      assert response["repo_id"] == "sample-repo"
      assert response["run_id"] == "RUN-sample-0001"
      assert is_boolean(response["has_more"])
      refute Jason.encode!(response) =~ "file://"
    end

    status = decode_json!("fixtures/run-status.json")
    assert status["surface"] == "rondo.core/v1"
    assert status["repo_id"] == "sample-repo"
    refute Jason.encode!(status) =~ "file://"
  end

  defp decode_json!(relative_path) do
    @asset_root
    |> Path.join(relative_path)
    |> File.read!()
    |> Jason.decode!()
  end
end
