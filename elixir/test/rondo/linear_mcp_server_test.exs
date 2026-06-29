defmodule Rondo.Linear.MCPServerTest do
  use Rondo.TestSupport

  alias Rondo.Linear.MCPServer

  defmodule FakeLinearClient do
    def graphql_raw(query, variables) do
      send(self(), {:graphql_raw_called, query, variables})

      case Process.get(:graphql_raw_result) do
        nil -> {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-1"}}}}
        result -> result
      end
    end
  end

  setup do
    previous_client_module = Application.get_env(:rondo, :linear_client_module)

    on_exit(fn ->
      case previous_client_module do
        nil -> Application.delete_env(:rondo, :linear_client_module)
        module -> Application.put_env(:rondo, :linear_client_module, module)
      end

      Process.delete(:graphql_raw_result)
    end)

    :ok
  end

  test "initialize advertises the tools capability" do
    assert {:reply, response} =
             MCPServer.handle_request(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-06-18"}
             })

    assert response["jsonrpc"] == "2.0"
    assert response["id"] == 1
    assert response["result"]["protocolVersion"] == "2025-06-18"
    assert response["result"]["capabilities"] == %{"tools" => %{}}
    assert response["result"]["serverInfo"]["name"] == "rondo-linear-graphql"
  end

  test "tools/list exposes the linear_graphql tool schema" do
    assert {:reply, response} =
             MCPServer.handle_request(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    [tool] = response["result"]["tools"]
    assert tool["name"] == "linear_graphql"
    assert tool["inputSchema"]["required"] == ["query"]
    assert tool["inputSchema"]["properties"]["variables"]["type"] == "object"
  end

  test "tools/call returns a structured success payload" do
    Application.put_env(:rondo, :linear_client_module, FakeLinearClient)

    assert {:reply, response} =
             MCPServer.handle_request(%{
               "jsonrpc" => "2.0",
               "id" => 3,
               "method" => "tools/call",
               "params" => %{
                 "arguments" => %{
                   "query" => "query Viewer { viewer { id } }",
                   "variables" => %{}
                 }
               }
             })

    assert_receive {:graphql_raw_called, "query Viewer { viewer { id } }", %{}}
    assert response["result"]["isError"] == false
    assert response["result"]["structuredContent"]["success"] == true
    assert response["result"]["structuredContent"]["body"]["data"]["viewer"]["id"] == "viewer-1"
  end

  test "tools/call returns clear invalid-args failures" do
    Application.put_env(:rondo, :linear_client_module, FakeLinearClient)

    assert {:reply, response} =
             MCPServer.handle_request(%{
               "jsonrpc" => "2.0",
               "id" => 4,
               "method" => "tools/call",
               "params" => %{"arguments" => %{"query" => "", "variables" => []}}
             })

    refute_received {:graphql_raw_called, _, _}
    assert response["result"]["isError"] == true
    assert response["result"]["structuredContent"]["error"]["type"] == "invalid_args"
    assert response["result"]["structuredContent"]["error"]["message"] =~ "non-empty"
  end

  test "tools/call returns missing-auth failures before calling Linear" do
    Application.put_env(:rondo, :linear_client_module, FakeLinearClient)
    Process.put(:graphql_raw_result, {:error, {:missing_linear_api_token}})

    assert {:reply, response} =
             MCPServer.handle_request(%{
               "jsonrpc" => "2.0",
               "id" => 5,
               "method" => "tools/call",
               "params" => %{
                 "arguments" => %{"query" => "query Viewer { viewer { id } }", "variables" => %{}}
               }
             })

    assert response["result"]["structuredContent"]["error"]["type"] == "missing_auth"
  end

  test "tools/call preserves GraphQL error bodies" do
    Application.put_env(:rondo, :linear_client_module, FakeLinearClient)

    Process.put(
      :graphql_raw_result,
      {:ok, %{"errors" => [%{"message" => "boom"}], "data" => nil}}
    )

    assert {:reply, response} =
             MCPServer.handle_request(%{
               "jsonrpc" => "2.0",
               "id" => 6,
               "method" => "tools/call",
               "params" => %{
                 "arguments" => %{"query" => "query Viewer { viewer { id } }", "variables" => %{}}
               }
             })

    assert response["result"]["isError"] == true
    assert response["result"]["structuredContent"]["error"]["type"] == "graphql_errors"
    assert Jason.encode!(response["result"]["structuredContent"]["error"]["body"]) =~ "boom"
  end
end
