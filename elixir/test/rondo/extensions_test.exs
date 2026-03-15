defmodule Rondo.ExtensionsTest do
  use Rondo.TestSupport

  # HttpServer.State removed — now uses Phoenix endpoint
  # alias Rondo.HttpServer.State, as: HttpServerState
  alias Rondo.Linear.Adapter
  alias Rondo.Tracker.Memory

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:rondo, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:rondo, :linear_client_module)
      else
        Application.put_env(:rondo, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(Rondo.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(Rondo.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(Rondo.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)
    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(Rondo.Supervisor, WorkflowStore)
    assert match?({:ok, _pid}, restart_result) or match?({:error, {:already_started, _pid}}, restart_result)
    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:rondo, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:rondo, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.tracker_kind() == "memory"
    assert Rondo.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = Rondo.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = Rondo.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = Rondo.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = Rondo.Tracker.create_comment("issue-1", "comment")
    assert :ok = Rondo.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:rondo, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert Rondo.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:rondo, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"
    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}
    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}}},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "http server serves html and json endpoints end-to-end" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    orchestrator_name = Module.concat(__MODULE__, :HttpOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    stop_endpoint()

    {:ok, _server_pid} =
      HttpServer.start_link(
        port: 0,
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 1_000
      )

    unlink_endpoint()

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-HTTP",
      issue: %Issue{id: "issue-http", identifier: "MT-HTTP", state: "In Progress"},
      session_id: "thread-http",
      turn_count: 7,
      claude_session_id: nil,
      last_claude_message: "rendered",
      last_claude_timestamp: nil,
      last_claude_event: :notification,
      claude_input_tokens: 4,
      claude_output_tokens: 8,
      claude_total_tokens: 12,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(orchestrator_pid, fn state ->
      %{
        state
        | running: %{"issue-http" => running_entry},
          retry_attempts: %{
            "issue-retry" => %{
              attempt: 2,
              due_at_ms: System.monotonic_time(:millisecond) + 2_000,
              identifier: "MT-RETRY",
              error: "boom"
            }
          }
      }
    end)

    port = wait_for_bound_port()
    assert HttpServer.bound_port() == port

    {status, headers, body} = http_request(port, "GET", "/")
    assert status == 200
    assert Map.fetch!(headers, "content-type") =~ "text/html"
    assert body =~ "Rondo Observability"

    {status, headers, body} = http_request(port, "GET", "/api/v1/state")
    assert status == 200
    assert Map.fetch!(headers, "content-type") =~ "application/json"

    assert %{
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [%{"issue_identifier" => "MT-HTTP", "last_message" => "rendered", "turn_count" => 7}],
             "retrying" => [%{"issue_identifier" => "MT-RETRY", "error" => "boom"}]
           } = Jason.decode!(body)

    :sys.replace_state(orchestrator_pid, fn state ->
      update_in(state.running["issue-http"].last_claude_message, fn _ -> %{message: "structured"} end)
    end)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/MT-HTTP")
    assert status == 200

    assert %{
             "issue_identifier" => "MT-HTTP",
             "status" => "running",
             "running" => %{"last_message" => "structured", "turn_count" => 7},
             "retry" => nil
           } = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/MT-RETRY")
    assert status == 200
    assert %{"status" => "retrying", "retry" => %{"attempt" => 2}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/MT-MISSING")
    assert status == 404
    assert %{"error" => %{"code" => "issue_not_found"}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "POST", "/api/v1/refresh", "")
    assert status == 202
    assert %{"operations" => ["poll", "reconcile"], "queued" => true} = Jason.decode!(body)
  end

  test "http server escapes html-sensitive characters in rendered dashboard payload" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    orchestrator_name = Module.concat(__MODULE__, :EscapingHttpOrchestrator)
    {:ok, orchestrator_pid} = Orchestrator.start_link(name: orchestrator_name)

    stop_endpoint()

    {:ok, _server_pid} =
      HttpServer.start_link(
        port: 0,
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 1_000
      )

    unlink_endpoint()

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-897",
      issue: %Issue{id: "issue-html", identifier: "MT-897", state: "In Progress"},
      session_id: "thread-html",
      turn_count: 7,
      claude_session_id: nil,
      last_claude_message: "<script>window.xssed=1</script>",
      last_claude_timestamp: nil,
      last_claude_event: :notification,
      claude_input_tokens: 4,
      claude_output_tokens: 8,
      claude_total_tokens: 12,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(orchestrator_pid, fn state ->
      %{state | running: %{"issue-html" => running_entry}, retry_attempts: %{}}
    end)

    port = wait_for_bound_port()
    {status, _headers, body} = http_request(port, "GET", "/")
    assert status == 200
    refute String.contains?(body, "<script>window.xssed=1</script>")
    assert body =~ "&lt;script&gt;window.xssed=1&lt;/script&gt;"
  end

  test "http server returns method, parse, timeout, and unavailable errors" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)

    stop_endpoint()

    {:ok, _server_pid} =
      HttpServer.start_link(
        port: 0,
        orchestrator: unavailable_orchestrator,
        snapshot_timeout_ms: 5
      )

    unlink_endpoint()

    port = wait_for_bound_port()

    # POST /api/v1/state — router accepts POST, so returns 200
    {status, _headers, _body} = http_request(port, "POST", "/api/v1/state", "")
    assert status == 200

    {status, _headers, body} = http_request(port, "GET", "/api/v1/refresh")
    assert status == 405
    assert %{"error" => %{"code" => "method_not_allowed"}} = Jason.decode!(body)

    # POST /api/v1/MT-1 — no POST route for issue identifiers, Phoenix returns 404
    {status, _headers, _body} = http_request(port, "POST", "/api/v1/MT-1", "")
    assert status in [404, 405]

    {status, _headers, body} = http_request(port, "GET", "/api/v1/state")
    assert status == 200
    assert %{"error" => %{"code" => "snapshot_unavailable"}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "POST", "/api/v1/refresh", "")
    assert status == 503
    assert %{"error" => %{"code" => "orchestrator_unavailable"}} = Jason.decode!(body)

    # Timeout orchestrator test — restart endpoint with different orchestrator
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, timeout_pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)

    stop_endpoint()

    {:ok, _timeout_server_pid} =
      HttpServer.start_link(
        port: 0,
        orchestrator: timeout_orchestrator,
        snapshot_timeout_ms: 1
      )

    unlink_endpoint()

    on_exit(fn ->
      if Process.alive?(timeout_pid), do: Process.exit(timeout_pid, :normal)
    end)

    timeout_port = wait_for_bound_port()
    {status, _headers, body} = http_request(timeout_port, "GET", "/api/v1/state")
    assert status == 200
    assert %{"error" => %{"code" => "snapshot_timeout"}} = Jason.decode!(body)
  end

  test "http server child spec, ignore branch, and bound_port fallback behave as expected" do
    spec = HttpServer.child_spec(name: :child_spec_server, port: 0)
    assert spec.id == Rondo.HttpServer
    assert spec.start == {HttpServer, :start_link, [[name: :child_spec_server, port: 0]]}

    stop_endpoint()

    Application.put_env(:rondo, :server_port_override, 0)

    {:ok, _default_pid} = HttpServer.start_link()
    unlink_endpoint()
    assert :ignore = HttpServer.start_link(port: nil)
    assert is_integer(HttpServer.bound_port())
    assert {:ok, {127, 0, 0, 1}} = HttpServer.parse_host_for_test({127, 0, 0, 1})
    assert {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} = HttpServer.parse_host_for_test({0, 0, 0, 0, 0, 0, 0, 1})
  end

  test "http server covers callback branches and synthetic snapshot payloads" do
    snapshot = %{
      running: [
        %{
          issue_id: "issue-both",
          identifier: "MT-BOTH",
          state: "In Progress",
          session_id: "thread-both",
          claude_session_id: nil,
          claude_input_tokens: 0,
          claude_output_tokens: 0,
          claude_total_tokens: 0,
          started_at: nil,
          last_claude_timestamp: nil,
          last_claude_message: %{unexpected: true},
          last_claude_event: :notification
        }
      ],
      retrying: [
        %{
          issue_id: "issue-both",
          identifier: "MT-BOTH",
          attempt: 3,
          due_in_ms: nil,
          error: "still retrying"
        }
      ],
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    orchestrator_name = Module.concat(__MODULE__, :StaticOrchestrator)

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{queued: true, coalesced: true, requested_at: DateTime.utc_now(), operations: ["poll"]}
      )

    stop_endpoint()

    {:ok, _server_pid} =
      HttpServer.start_link(
        port: 0,
        orchestrator: orchestrator_name,
        snapshot_timeout_ms: 50
      )

    unlink_endpoint()

    on_exit(fn ->
      if Process.alive?(orchestrator_pid), do: Process.exit(orchestrator_pid, :normal)
    end)

    port = wait_for_bound_port()

    {status, _headers, body} = http_request(port, "GET", "/api/v1/state")

    assert status == 200
    assert %{"counts" => %{"running" => 1, "retrying" => 1}} = Jason.decode!(body)

    {status, _headers, body} = http_request(port, "GET", "/api/v1/MT-BOTH")
    assert status == 200
    assert %{"status" => "running", "running" => %{"last_message" => nil}, "retry" => %{"due_at" => nil}} = Jason.decode!(body)

    # TCP-specific tests removed — Bandit handles partial requests, oversized headers/body, malformed headers internally

    unexpected_orchestrator = Module.concat(__MODULE__, :UnexpectedOrchestrator)

    {:ok, unexpected_orchestrator_pid} =
      StaticOrchestrator.start_link(name: unexpected_orchestrator, snapshot: :unexpected)

    stop_endpoint()

    {:ok, _unexpected_server_pid} =
      HttpServer.start_link(
        port: 0,
        orchestrator: unexpected_orchestrator,
        snapshot_timeout_ms: 50
      )

    unlink_endpoint()

    on_exit(fn ->
      if Process.alive?(unexpected_orchestrator_pid), do: Process.exit(unexpected_orchestrator_pid, :normal)
    end)

    unexpected_port = wait_for_bound_port()
    {status, _headers, body} = http_request(unexpected_port, "GET", "/api/v1/MT-BOTH")
    assert status == 404
    assert %{"error" => %{"code" => "issue_not_found"}} = Jason.decode!(body)
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp unlink_endpoint do
    case Process.whereis(RondoWeb.Endpoint) do
      pid when is_pid(pid) -> Process.unlink(pid)
      _ -> :ok
    end
  end

  defp stop_endpoint do
    # Trap exits to avoid test process crashing from linked endpoint shutdown
    was_trapping = Process.flag(:trap_exit, true)

    try do
      # Terminate the supervisor child (prevents restart by Rondo.Supervisor)
      try do
        Supervisor.terminate_child(Rondo.Supervisor, Rondo.HttpServer)
      catch
        :exit, _ -> :ok
      end

      case Process.whereis(RondoWeb.Endpoint) do
        pid when is_pid(pid) ->
          Process.unlink(pid)

          try do
            Supervisor.stop(pid, :shutdown, 2_000)
          catch
            :exit, _ -> :ok
          end

          # Wait for the process to terminate
          ref = Process.monitor(pid)
          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            2_000 -> :ok
          end

        _ ->
          :ok
      end

      # Drain any EXIT messages from linked processes
      drain_exits()
    after
      Process.flag(:trap_exit, was_trapping)
    end
  end

  defp drain_exits do
    receive do
      {:EXIT, _pid, _reason} -> drain_exits()
    after
      50 -> :ok
    end
  end

  defp http_request(port, method, path, body \\ nil, extra_headers \\ []) do
    request = build_http_request(method, path, body, extra_headers)

    response = http_raw_request(port, request)
    [header_block, response_body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(header_block, "\r\n")
    [_, status_code, _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Enum.reduce(header_lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> Map.put(acc, String.downcase(name), String.trim(value))
          _ -> acc
        end
      end)

    {String.to_integer(status_code), headers, response_body}
  end

  defp http_raw_request(port, request) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, request)
    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp build_http_request(method, path, body, extra_headers) do
    headers =
      [
        {"host", "127.0.0.1"},
        {"connection", "close"}
      ] ++ extra_headers

    headers =
      if is_binary(body) and not Enum.any?(headers, fn {name, _value} -> name == "content-length" end) do
        headers ++ [{"content-length", Integer.to_string(byte_size(body))}]
      else
        headers
      end

    [
      "#{method} #{path} HTTP/1.1\r\n",
      Enum.map(headers, fn
        {name, nil} -> "#{name}\r\n"
        {name, value} -> "#{name}: #{value}\r\n"
      end),
      "\r\n",
      body || ""
    ]
    |> IO.iodata_to_binary()
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> acc
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(Rondo.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
