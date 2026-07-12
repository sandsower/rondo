defmodule RondoWeb.CoreApiControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  defmodule CoreOrchestratorStub do
    @spec submit_execution_request(GenServer.server(), map()) :: term()
    def submit_execution_request(server, params) do
      config = Application.fetch_env!(:rondo, :core_api_controller_test)
      send(config.test_pid, {:submit_execution_request, server, params})
      config.submit_result
    end
  end

  defmodule EventFeedStub do
    @spec run_status(map()) :: term()
    def run_status(request) do
      config = Application.fetch_env!(:rondo, :core_api_controller_test)
      send(config.test_pid, {:run_status, request})
      config.status_result
    end

    @spec run_events(map()) :: term()
    def run_events(request) do
      config = Application.fetch_env!(:rondo, :core_api_controller_test)
      send(config.test_pid, {:run_events, request})
      config.events_result
    end
  end

  defmodule IdentityStub do
    @spec snapshot(GenServer.server()) :: map()
    def snapshot(orchestrator) do
      send(self_config().test_pid, {:health_snapshot, orchestrator})
      self_config().health_result
    end

    defp self_config, do: Application.fetch_env!(:rondo, :core_api_controller_test)
  end

  setup do
    previous_endpoint_config = Application.get_env(:rondo, RondoWeb.Endpoint, [])
    previous_test_config = Application.get_env(:rondo, :core_api_controller_test)

    endpoint_config =
      previous_endpoint_config
      |> Keyword.put(:core_orchestrator, CoreOrchestratorStub)
      |> Keyword.put(:core_event_feed, EventFeedStub)
      |> Keyword.put(:core_identity, IdentityStub)
      |> Keyword.put(:core_service_id, "service-test")
      |> Keyword.put(:orchestrator, :orchestrator_test)

    Application.put_env(:rondo, RondoWeb.Endpoint, endpoint_config)
    start_supervised!(RondoWeb.Endpoint)

    set_stub_results(
      {:ok,
       %{
         surface: "rondo.core/v1",
         service_id: "service-test",
         repo_id: "repo-test",
         run_id: "run-test",
         status: "running",
         event_cursor: "rondo.core/v1:0",
         deduplicated: false,
         run_dir: "/must/not/leak"
       }},
      {:ok,
       %{
         "surface" => "rondo.core/v1",
         "repo_id" => "repo-test",
         "run_id" => "run-test",
         "status" => "running",
         "last_event" => nil,
         "evidence_pointers" => [],
         "event_cursor" => "rondo.core/v1:0",
         "run_dir" => "/must/not/leak"
       }},
      {:ok,
       %{
         "surface" => "rondo.core/v1",
         "repo_id" => "repo-test",
         "run_id" => "run-test",
         "events" => [],
         "next_event_cursor" => "rondo.core/v1:0",
         "has_more" => false,
         "run_dir" => "/must/not/leak"
       }},
      %{
        "surface" => "rondo.core/v1",
        "runtime_version" => "0.1.0",
        "instance_id" => "019b8941-4a0c-7ad5-b7ef-cb3c45e4a819",
        "service_mode" => "trackerless_core",
        "ready" => true,
        "active_run_count" => 0,
        "internal_path" => "/must/not/leak"
      }
    )

    on_exit(fn ->
      Application.put_env(:rondo, RondoWeb.Endpoint, previous_endpoint_config)

      if is_nil(previous_test_config) do
        Application.delete_env(:rondo, :core_api_controller_test)
      else
        Application.put_env(:rondo, :core_api_controller_test, previous_test_config)
      end
    end)

    :ok
  end

  test "GET health returns the exact loopback Core identity without internal state" do
    conn = request(:get, "/api/v1/health")

    assert decoded_response(conn, 200) == %{
             "active_run_count" => 0,
             "instance_id" => "019b8941-4a0c-7ad5-b7ef-cb3c45e4a819",
             "ready" => true,
             "runtime_version" => "0.1.0",
             "service_mode" => "trackerless_core",
             "surface" => "rondo.core/v1"
           }

    assert_receive {:health_snapshot, :orchestrator_test}
    refute conn.resp_body =~ "internal_path"
    refute conn.resp_body =~ "/must/not/leak"
  end

  test "POST execution-requests submits a validated request and returns 202 for a new run" do
    conn =
      request(:post, "/api/v1/execution-requests", %{
        "manifest_path" => "/exports/slice.json",
        "manifest_sha256" => String.duplicate("a", 64),
        "repo_id" => "repo-test"
      })

    assert decoded_response(conn, 202) == %{
             "deduplicated" => false,
             "event_cursor" => "rondo.core/v1:0",
             "repo_id" => "repo-test",
             "run_id" => "run-test",
             "service_id" => "service-test",
             "status" => "running",
             "surface" => "rondo.core/v1"
           }

    refute Map.has_key?(decoded_response(conn, 202), "run_dir")

    assert_receive {:submit_execution_request, :orchestrator_test,
                    %{
                      manifest_path: "/exports/slice.json",
                      manifest_sha256: digest,
                      repo_id: "repo-test"
                    }}

    assert digest == String.duplicate("a", 64)
  end

  test "POST execution-requests returns 200 for an idempotent existing run" do
    set_submit_result(
      {:ok,
       %{
         surface: "rondo.core/v1",
         service_id: "service-test",
         repo_id: "repo-test",
         run_id: "run-existing",
         status: "running",
         event_cursor: "rondo.core/v1:4",
         deduplicated: true
       }}
    )

    conn = request(:post, "/api/v1/execution-requests", valid_submit_params())

    assert %{"deduplicated" => true, "run_id" => "run-existing"} = decoded_response(conn, 200)
  end

  test "POST execution-requests rejects missing or blank request fields before submission" do
    for params <- [
          %{},
          Map.put(valid_submit_params(), "manifest_path", " "),
          Map.put(valid_submit_params(), "manifest_sha256", ""),
          Map.put(valid_submit_params(), "repo_id", nil)
        ] do
      conn = request(:post, "/api/v1/execution-requests", params)
      assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(conn, 400)
    end

    refute_received {:submit_execution_request, _, _}
  end

  test "POST preserves a nonblank manifest path byte-for-byte and requires a lowercase digest" do
    manifest_path = "/exports/ slice.json "
    conn = request(:post, "/api/v1/execution-requests", Map.put(valid_submit_params(), "manifest_path", manifest_path))
    assert %{"run_id" => "run-test"} = decoded_response(conn, 202)
    assert_receive {:submit_execution_request, :orchestrator_test, %{manifest_path: ^manifest_path}}

    uppercase_digest = String.duplicate("A", 64)
    invalid = request(:post, "/api/v1/execution-requests", Map.put(valid_submit_params(), "manifest_sha256", uppercase_digest))
    assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(invalid, 400)
    refute_received {:submit_execution_request, _, _}
  end

  test "POST execution-requests rejects surrounding repo_id whitespace and echoes accepted IDs exactly" do
    for repo_id <- [
          " repo-test",
          "repo-test ",
          "\trepo-test",
          "repo-test\n",
          "repo\0test",
          String.duplicate("r", 513)
        ] do
      conn = request(:post, "/api/v1/execution-requests", Map.put(valid_submit_params(), "repo_id", repo_id))
      assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(conn, 400)
    end

    refute_received {:submit_execution_request, _, _}

    exact_repo_id = "repo exact/id"

    set_submit_result(
      {:ok,
       %{
         surface: "rondo.core/v1",
         service_id: "service-test",
         repo_id: exact_repo_id,
         run_id: "run-exact",
         status: "running",
         event_cursor: "rondo.core/v1:0",
         deduplicated: false
       }}
    )

    conn = request(:post, "/api/v1/execution-requests", Map.put(valid_submit_params(), "repo_id", exact_repo_id))

    assert %{"repo_id" => ^exact_repo_id} = decoded_response(conn, 202)
    assert_receive {:submit_execution_request, :orchestrator_test, %{repo_id: ^exact_repo_id}}
  end

  test "POST rejects malformed internal success responses without emitting nullable handles" do
    valid = %{
      surface: "rondo.core/v1",
      service_id: "service-test",
      repo_id: "repo-test",
      run_id: "run-test",
      status: "running",
      event_cursor: "rondo.core/v1:0",
      deduplicated: false
    }

    malformed = [
      Map.delete(valid, :surface),
      Map.put(valid, :surface, "rondo.core/v2"),
      Map.put(valid, :service_id, ""),
      Map.put(valid, :run_id, " "),
      Map.put(valid, :status, ""),
      Map.put(valid, :event_cursor, "not-a-core-cursor"),
      Map.put(valid, :deduplicated, "false"),
      Map.put(valid, :repo_id, "other-repo")
    ]

    for run <- malformed do
      set_submit_result({:ok, run})
      conn = request(:post, "/api/v1/execution-requests", valid_submit_params())
      assert %{"error" => %{"code" => "orchestrator_unavailable"}} = decoded_response(conn, 503)
      refute conn.resp_body =~ "other-repo"
      refute conn.resp_body =~ "not-a-core-cursor"
    end
  end

  test "POST execution-requests maps stable domain failures without exposing raw terms" do
    cases = [
      {{:error, :invalid_request}, 400, "invalid_request"},
      {{:error, :digest_conflict}, 409, "digest_conflict"},
      {{:error, {:invalid_manifest, %{raw_manifest: "TOP-SECRET-MANIFEST"}}}, 422, "invalid_manifest"},
      {{:error, {:unapproved_manifest, "TOP-SECRET-APPROVAL"}}, 422, "unapproved_manifest"},
      {{:error, :capacity_exhausted}, 429, "capacity_exhausted"},
      {:unavailable, 503, "orchestrator_unavailable"}
    ]

    for {result, status, code} <- cases do
      set_submit_result(result)
      conn = request(:post, "/api/v1/execution-requests", valid_submit_params())
      assert conn.status == status
      body = conn.resp_body

      assert %{"error" => %{"code" => ^code}} = Jason.decode!(body)
      refute body =~ "TOP-SECRET"
    end

    set_submit_result({:error, :not_found})
    unsupported = request(:post, "/api/v1/execution-requests", valid_submit_params())
    assert %{"error" => %{"code" => "orchestrator_unavailable"}} = decoded_response(unsupported, 503)
    refute unsupported.resp_body =~ "not_found"
  end

  test "GET run status requires repo_id and proxies the structured Core response" do
    invalid_conn = request(:get, "/api/v1/runs/run-test")
    assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(invalid_conn, 400)

    conn = request(:get, "/api/v1/runs/run-test?repo_id=repo-test")

    assert decoded_response(conn, 200) == %{
             "surface" => "rondo.core/v1",
             "repo_id" => "repo-test",
             "run_id" => "run-test",
             "status" => "running",
             "last_event" => nil,
             "evidence_pointers" => [],
             "event_cursor" => "rondo.core/v1:0"
           }

    refute conn.resp_body =~ "run_dir"

    assert_receive {:run_status,
                    %{
                      event_cursor: nil,
                      repo_id: "repo-test",
                      run_id: "run-test",
                      service_id: "service-test"
                    }}
  end

  test "GET run status rejects a mismatched EventFeed run identity" do
    set_status_result(
      {:ok,
       %{
         "run_id" => "other-run",
         "status" => "running",
         "last_event" => nil,
         "evidence_pointers" => [],
         "event_cursor" => "rondo.core/v1:0"
       }}
    )

    conn = request(:get, "/api/v1/runs/run-test?repo_id=repo-test")
    assert %{"error" => %{"code" => "core_unavailable"}} = decoded_response(conn, 503)
    refute conn.resp_body =~ "other-run"
  end

  test "GET run status maps not found and unavailable responses" do
    set_status_result({:error, {:run_not_found, "TOP-SECRET-LOOKUP"}})
    not_found = request(:get, "/api/v1/runs/missing?repo_id=repo-test")
    assert %{"error" => %{"code" => "run_not_found"}} = decoded_response(not_found, 404)
    refute not_found.resp_body =~ "TOP-SECRET"

    set_status_result({:error, :unavailable})
    unavailable = request(:get, "/api/v1/runs/run-test?repo_id=repo-test")
    assert %{"error" => %{"code" => "core_unavailable"}} = decoded_response(unavailable, 503)
  end

  test "GET run observations reject surrounding repo_id whitespace before the event feed" do
    for path <- [
          "/api/v1/runs/run-test?repo_id=+repo-test",
          "/api/v1/runs/run-test/events?repo_id=repo-test+"
        ] do
      conn = request(:get, path)
      assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(conn, 400)
    end

    refute_received {:run_status, _request}
    refute_received {:run_events, _request}
  end

  test "GET run observations preserve and echo an accepted repo_id exactly" do
    repo_id = "repo exact/id"
    query = URI.encode_query(%{"repo_id" => repo_id})

    set_status_result(
      {:ok,
       %{
         "surface" => "rondo.core/v1",
         "repo_id" => repo_id,
         "run_id" => "run-test",
         "status" => "running",
         "last_event" => nil,
         "evidence_pointers" => [],
         "event_cursor" => "rondo.core/v1:0"
       }}
    )

    conn = request(:get, "/api/v1/runs/run-test?" <> query)

    assert %{"repo_id" => ^repo_id, "run_id" => "run-test", "surface" => "rondo.core/v1"} =
             decoded_response(conn, 200)

    assert_receive {:run_status, %{repo_id: ^repo_id, run_id: "run-test"}}
  end

  test "GET status and events reject oversized or control identifiers before the feed" do
    invalid_repo_ids = [String.duplicate("r", 513), "repo\0id", "repo\nid"]
    invalid_run_ids = [String.duplicate("r", 513), "run\0id", "run\nid"]

    for repo_id <- invalid_repo_ids,
        suffix <- ["", "/events"] do
      query = URI.encode_query(%{"repo_id" => repo_id})
      conn = request(:get, "/api/v1/runs/run-test#{suffix}?#{query}")
      assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(conn, 400)
    end

    for run_id <- invalid_run_ids,
        suffix <- ["", "/events"] do
      encoded_run_id = URI.encode(run_id, &URI.char_unreserved?/1)
      conn = request(:get, "/api/v1/runs/#{encoded_run_id}#{suffix}?repo_id=repo-test")
      assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(conn, 400)
    end

    refute_received {:run_status, _request}
    refute_received {:run_events, _request}
  end

  test "GET status and events preserve valid reserved identifier characters exactly" do
    repo_id = "repo:*?[opaque]"
    run_id = "run:*?[opaque]"
    encoded_run_id = URI.encode(run_id, &URI.char_unreserved?/1)
    query = URI.encode_query(%{"repo_id" => repo_id})

    set_status_result(
      {:ok,
       %{
         "surface" => "rondo.core/v1",
         "repo_id" => repo_id,
         "run_id" => run_id,
         "status" => "running",
         "last_event" => nil,
         "evidence_pointers" => [],
         "event_cursor" => "rondo.core/v1:0"
       }}
    )

    status = request(:get, "/api/v1/runs/#{encoded_run_id}?#{query}")
    assert %{"repo_id" => ^repo_id, "run_id" => ^run_id} = decoded_response(status, 200)
    assert_receive {:run_status, %{repo_id: ^repo_id, run_id: ^run_id}}

    set_events_result(
      {:ok,
       %{
         "surface" => "rondo.core/v1",
         "repo_id" => repo_id,
         "run_id" => run_id,
         "events" => [],
         "next_event_cursor" => "rondo.core/v1:0",
         "has_more" => false
       }}
    )

    events = request(:get, "/api/v1/runs/#{encoded_run_id}/events?#{query}")
    assert %{"repo_id" => ^repo_id, "run_id" => ^run_id} = decoded_response(events, 200)
    assert_receive {:run_events, %{repo_id: ^repo_id, run_id: ^run_id}}
  end

  test "GET run events requires repo_id and forwards the opaque cursor" do
    invalid_conn = request(:get, "/api/v1/runs/run-test/events")
    assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(invalid_conn, 400)

    conn =
      request(
        :get,
        "/api/v1/runs/run-test/events?repo_id=repo-test&cursor=rondo.core%2Fv1%3A7"
      )

    assert decoded_response(conn, 200) == %{
             "surface" => "rondo.core/v1",
             "repo_id" => "repo-test",
             "run_id" => "run-test",
             "events" => [],
             "next_event_cursor" => "rondo.core/v1:0",
             "has_more" => false
           }

    refute conn.resp_body =~ "run_dir"

    assert_receive {:run_events,
                    %{
                      event_cursor: "rondo.core/v1:7",
                      repo_id: "repo-test",
                      run_id: "run-test",
                      service_id: "service-test"
                    }}
  end

  test "GET run events maps not found and unavailable responses" do
    set_events_result({:error, :run_not_found})
    not_found = request(:get, "/api/v1/runs/missing/events?repo_id=repo-test")
    assert %{"error" => %{"code" => "run_not_found"}} = decoded_response(not_found, 404)

    set_events_result({:error, :unavailable})
    unavailable = request(:get, "/api/v1/runs/run-test/events?repo_id=repo-test")
    assert %{"error" => %{"code" => "core_unavailable"}} = decoded_response(unavailable, 503)

    set_events_result({:error, :invalid_cursor})

    past_end =
      request(
        :get,
        "/api/v1/runs/run-test/events?repo_id=repo-test&cursor=rondo.core%2Fv1%3A999"
      )

    assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(past_end, 400)
  end

  test "Core event index corruption maps to core_unavailable without leaking details" do
    corruption =
      {:error, {:core_event_index_corrupt, {:invalid_descriptor, 0, {:unsupported_type, "secret-future-type"}}}}

    set_status_result(corruption)
    status = request(:get, "/api/v1/runs/run-test?repo_id=repo-test")
    assert %{"error" => %{"code" => "core_unavailable"}} = decoded_response(status, 503)
    refute status.resp_body =~ "secret-future-type"

    set_events_result(corruption)
    events = request(:get, "/api/v1/runs/run-test/events?repo_id=repo-test")
    assert %{"error" => %{"code" => "core_unavailable"}} = decoded_response(events, 503)
    refute events.resp_body =~ "secret-future-type"
  end

  test "GET run events rejects mismatched feed echoes and malformed response cursors" do
    set_events_result(
      {:ok,
       %{
         "surface" => "rondo.core/v1",
         "repo_id" => "other-repo",
         "run_id" => "run-test",
         "events" => [],
         "next_event_cursor" => "rondo.core/v1:0",
         "has_more" => false
       }}
    )

    mismatch = request(:get, "/api/v1/runs/run-test/events?repo_id=repo-test")
    assert %{"error" => %{"code" => "core_unavailable"}} = decoded_response(mismatch, 503)
    refute mismatch.resp_body =~ "other-repo"

    set_events_result({:ok, %{"events" => [], "next_event_cursor" => "not-a-core-cursor"}})
    malformed = request(:get, "/api/v1/runs/run-test/events?repo_id=repo-test")
    assert %{"error" => %{"code" => "core_unavailable"}} = decoded_response(malformed, 503)
    refute malformed.resp_body =~ "not-a-core-cursor"
  end

  test "GET run events requires and allowlists the boolean has_more field" do
    base_response = %{
      "surface" => "rondo.core/v1",
      "repo_id" => "repo-test",
      "run_id" => "run-test",
      "events" => [],
      "next_event_cursor" => "rondo.core/v1:0"
    }

    for response <- [base_response, Map.put(base_response, "has_more", "false")] do
      set_events_result({:ok, response})
      conn = request(:get, "/api/v1/runs/run-test/events?repo_id=repo-test")
      assert %{"error" => %{"code" => "core_unavailable"}} = decoded_response(conn, 503)
    end

    set_events_result({:ok, Map.merge(base_response, %{"has_more" => true, "run_dir" => "/must/not/leak"})})
    valid = request(:get, "/api/v1/runs/run-test/events?repo_id=repo-test")

    assert %{"has_more" => true, "surface" => "rondo.core/v1"} = decoded_response(valid, 200)
    refute valid.resp_body =~ "run_dir"
  end

  test "GET run events rejects invalid cursor syntax before the event feed" do
    for cursor <- ["", "7", "rondo.core/v1:-1", "rondo.core/v1:7tail", "other.core/v1:7"] do
      path = "/api/v1/runs/run-test/events?" <> URI.encode_query(%{"repo_id" => "repo-test", "cursor" => cursor})
      conn = request(:get, path)
      assert %{"error" => %{"code" => "invalid_request"}} = decoded_response(conn, 400)
    end

    refute_received {:run_events, _request}
  end

  test "Endpoint rejects non-loopback Core bodies before JSON or multipart parsing" do
    expected = %{
      "error" => %{
        "code" => "loopback_required",
        "message" => "Rondo Core API is available only to loopback callers"
      }
    }

    multipart_body =
      "--rondo-boundary\r\n" <>
        "Content-Disposition: form-data; name=\"repo_id\"\r\n\r\n" <>
        "TOP-SECRET\r\n--rondo-boundary--\r\n"

    cases = [
      {:get, "/api/v1/health", "", "application/json"},
      {:post, "/api/v1/execution-requests", ~s({"manifest_path":), "application/json"},
      {:get, "/api/v1/runs/run-test?repo_id=repo-test", ~s({"invalid":), "application/json"},
      {:get, "/api/v1/runs/run-test/events?repo_id=repo-test", multipart_body, "multipart/form-data; boundary=rondo-boundary"}
    ]

    for {method, path, body, content_type} <- cases do
      conn =
        endpoint_request(method, path, body, content_type, remote_ip: {2001, 0xDB8, 0, 0, 0, 0, 0, 1})

      assert decoded_response(conn, 403) == expected
      refute conn.resp_body =~ "TOP-SECRET"
    end

    refute_received {:submit_execution_request, _, _}
    refute_received {:run_status, _request}
    refute_received {:run_events, _request}

    static =
      endpoint_request(:get, "/dashboard.css", "", "text/plain", remote_ip: {192, 0, 2, 10})

    assert static.status == 200
  end

  test "Endpoint maps malformed loopback Core JSON to the stable invalid-request envelope" do
    expected = %{
      "error" => %{
        "code" => "invalid_request",
        "message" => "request body must contain valid JSON"
      }
    }

    for path <- [
          "/api/v1/execution-requests",
          "/api/v1/runs/run-test?repo_id=repo-test",
          "/api/v1/runs/run-test/events?repo_id=repo-test"
        ],
        content_type <- [
          "application/json",
          "Application/JSON",
          "application/problem+JSON; charset=utf-8"
        ] do
      conn = endpoint_request(:post, path, ~s({"broken":), content_type, remote_ip: {127, 0, 0, 1})
      assert decoded_response(conn, 400) == expected
    end

    refute_received {:submit_execution_request, _, _}
    refute_received {:run_status, _request}
    refute_received {:run_events, _request}
  end

  test "Endpoint keeps the generic malformed-JSON envelope outside Core" do
    assert_raise Plug.Parsers.ParseError, fn ->
      endpoint_request(:post, "/not-a-core-route", ~s({"broken":), "application/json", remote_ip: {127, 0, 0, 1})
    end
  end

  test "Core endpoints reject non-loopback callers before parsing or invoking dependencies" do
    expected = %{
      "error" => %{
        "code" => "loopback_required",
        "message" => "Rondo Core API is available only to loopback callers"
      }
    }

    post_conn =
      request(:post, "/api/v1/execution-requests", %{}, remote_ip: {192, 0, 2, 10})

    assert decoded_response(post_conn, 403) == expected
    refute_received {:submit_execution_request, _, _}

    for path <- [
          "/api/v1/health",
          "/api/v1/runs/run-test?repo_id=repo-test",
          "/api/v1/runs/run-test/events?repo_id=repo-test"
        ] do
      conn = request(:get, path, nil, remote_ip: {2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert decoded_response(conn, 403) == expected
    end

    refute_received {:run_status, _request}
    refute_received {:run_events, _request}
  end

  test "Core endpoints accept IPv4 127/8 and IPv6 loopback callers" do
    health_conn = request(:get, "/api/v1/health", nil, remote_ip: {127, 42, 5, 9})
    assert %{"ready" => true} = decoded_response(health_conn, 200)

    status_conn =
      request(:get, "/api/v1/runs/run-test?repo_id=repo-test", nil, remote_ip: {127, 42, 5, 9})

    assert %{"status" => "running"} = decoded_response(status_conn, 200)
    assert_receive {:run_status, _request}

    events_conn =
      request(:get, "/api/v1/runs/run-test/events?repo_id=repo-test", nil, remote_ip: {0, 0, 0, 0, 0, 0, 0, 1})

    assert %{"events" => []} = decoded_response(events_conn, 200)
    assert_receive {:run_events, _request}
  end

  defp valid_submit_params do
    %{
      "manifest_path" => "/exports/slice.json",
      "manifest_sha256" => String.duplicate("a", 64),
      "repo_id" => "repo-test"
    }
  end

  defp set_stub_results(submit_result, status_result, events_result, health_result) do
    Application.put_env(:rondo, :core_api_controller_test, %{
      test_pid: self(),
      submit_result: submit_result,
      status_result: status_result,
      events_result: events_result,
      health_result: health_result
    })
  end

  defp set_submit_result(result) do
    update_stub_result(:submit_result, result)
  end

  defp set_status_result(result) do
    update_stub_result(:status_result, result)
  end

  defp set_events_result(result) do
    update_stub_result(:events_result, result)
  end

  defp update_stub_result(key, result) do
    config = Application.fetch_env!(:rondo, :core_api_controller_test)
    Application.put_env(:rondo, :core_api_controller_test, Map.put(config, key, result))
  end

  defp request(method, path, params \\ nil, opts \\ []) do
    request_conn = conn(method, path, params)
    request_conn = %{request_conn | remote_ip: Keyword.get(opts, :remote_ip, request_conn.remote_ip)}

    request_conn
    |> fetch_query_params()
    |> RondoWeb.Router.call(RondoWeb.Router.init([]))
  end

  defp endpoint_request(method, path, body, content_type, opts) do
    request_conn =
      method
      |> conn(path, body)
      |> put_req_header("content-type", content_type)

    request_conn = %{request_conn | remote_ip: Keyword.fetch!(opts, :remote_ip)}
    RondoWeb.Endpoint.call(request_conn, [])
  end

  defp decoded_response(conn, status) do
    assert conn.state == :sent
    assert conn.status == status
    Jason.decode!(conn.resp_body)
  end
end
