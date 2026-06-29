defmodule Rondo.Linear.MCPServer do
  @moduledoc """
  Minimal Model Context Protocol server that exposes a single `linear_graphql` tool.

  Claude Code connects to this server through the repo-local `.mcp.json`
  configuration and exchanges MCP JSON-RPC messages over stdio.
  """

  require Logger

  alias Rondo.{Config, Linear.Client}

  @jsonrpc_version "2.0"
  @protocol_version "2025-06-18"
  @server_name "rondo-linear-graphql"
  @server_version "0.1.0"
  @tool_name "linear_graphql"

  @type request :: map()
  @type response :: map()

  @spec main() :: :ok
  def main do
    loop()
  end

  @spec handle_request(request(), keyword()) :: {:reply, response()} | :ignore
  def handle_request(message, opts \\ []) when is_map(message) and is_list(opts) do
    client_module = Keyword.get(opts, :client_module, client_module())

    case Map.get(message, "method") do
      "initialize" ->
        {:reply, jsonrpc_result(message, initialize_result(message))}

      "tools/list" ->
        {:reply, jsonrpc_result(message, tools_list_result())}

      "tools/call" ->
        {:reply, jsonrpc_result(message, tools_call_result(message, client_module))}

      _other when is_map_key(message, "id") ->
        {:reply, jsonrpc_error(message, -32_601, "Method not found", %{method: Map.get(message, "method")})}

      _other ->
        :ignore
    end
  end

  defp loop do
    case read_message() do
      :eof ->
        :ok

      {:ok, message} ->
        case handle_request(message) do
          {:reply, response} ->
            write_message(response)

          :ignore ->
            :ok
        end

        loop()

      {:error, reason} ->
        Logger.warning("linear_graphql MCP transport error: #{inspect(reason)}")
        loop()
    end
  end

  defp read_message do
    with {:ok, headers} <- read_headers(%{}),
         {:ok, content_length} <- parse_content_length(headers),
         {:ok, body} <- read_body(content_length),
         {:ok, message} <- decode_message(body) do
      {:ok, message}
    else
      :eof -> :eof
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_headers(headers) do
    case IO.read(:stdio, :line) do
      :eof ->
        if headers == %{}, do: :eof, else: {:ok, headers}

      line ->
        line
        |> String.trim_trailing("\r\n")
        |> read_header_line(headers)
    end
  end

  defp read_header_line("", headers), do: {:ok, headers}

  defp read_header_line(line, headers) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        read_headers(Map.put(headers, String.downcase(String.trim(name)), String.trim(value)))

      _ ->
        read_headers(headers)
    end
  end

  defp parse_content_length(headers) when is_map(headers) do
    case Map.get(headers, "content-length") do
      nil ->
        {:error, :missing_content_length}

      value ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> {:ok, length}
          _ -> {:error, {:invalid_content_length, value}}
        end
    end
  end

  defp read_body(length) when is_integer(length) and length >= 0 do
    case IO.binread(:stdio, length) do
      data when is_binary(data) and byte_size(data) == length -> {:ok, data}
      :eof -> :eof
      other -> {:error, {:invalid_body_read, other}}
    end
  end

  defp decode_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = message} -> {:ok, message}
      {:ok, other} -> {:error, {:invalid_jsonrpc_message, other}}
      {:error, reason} -> {:error, {:json_decode_error, reason}}
    end
  end

  defp write_message(message) when is_map(message) do
    encoded = Jason.encode!(message)
    payload = "Content-Length: #{byte_size(encoded)}\r\n\r\n#{encoded}"
    IO.binwrite(:stdio, payload)
  end

  defp initialize_result(message) do
    params = Map.get(message, "params") || %{}
    protocol_version = Map.get(params, "protocolVersion") || @protocol_version

    %{
      "protocolVersion" => protocol_version,
      "capabilities" => %{
        "tools" => %{}
      },
      "serverInfo" => %{
        "name" => @server_name,
        "version" => server_version()
      }
    }
  end

  defp tools_list_result do
    %{
      "tools" => [tool_definition()]
    }
  end

  defp tools_call_result(message, client_module) do
    with {:ok, query, variables} <- extract_call_arguments(message),
         :ok <- validate_query(query),
         :ok <- validate_variables(variables),
         :ok <- validate_linear_auth() do
      client_module
      |> graphql_call_result(query, variables)
      |> graphql_result_to_tool_response(query, variables)
    else
      {:error, error} -> tool_failure(error)
    end
  end

  defp graphql_call_result(client_module, query, variables) do
    case client_module.graphql_raw(query, variables) do
      {:ok, body} ->
        {:ok, body}

      {:error, {:linear_api_request, reason}} ->
        {:error,
         %{
           "type" => "transport_error",
           "message" => "Linear GraphQL transport failed",
           "reason" => inspect(reason)
         }}

      {:error, {:linear_api_status, status, body}} ->
        {:error,
         %{
           "type" => "transport_error",
           "message" => "Linear GraphQL returned non-200 HTTP status",
           "status" => status,
           "body" => body
         }}

      {:error, {:linear_api_status, status}} ->
        {:error,
         %{
           "type" => "transport_error",
           "message" => "Linear GraphQL returned non-200 HTTP status",
           "status" => status
         }}

      {:error, {:missing_linear_api_token}} ->
        {:error,
         %{
           "type" => "missing_auth",
           "message" => "LINEAR_API_KEY is not configured"
         }}

      {:error, reason} ->
        {:error,
         %{
           "type" => "transport_error",
           "message" => "Linear GraphQL request failed",
           "reason" => inspect(reason)
         }}

      other ->
        {:error,
         %{
           "type" => "unexpected_result",
           "message" => "Linear GraphQL client returned an unexpected value",
           "result" => inspect(other)
         }}
    end
  end

  defp graphql_result_to_tool_response({:ok, %{"errors" => errors} = body}, _query, _variables)
       when is_list(errors) and errors != [] do
    tool_failure(%{
      "type" => "graphql_errors",
      "message" => "Linear GraphQL returned errors",
      "errors" => errors,
      "body" => body
    })
  end

  defp graphql_result_to_tool_response({:ok, body}, query, variables) when is_map(body) do
    tool_success(%{
      "query" => query,
      "variables" => variables,
      "body" => body
    })
  end

  defp graphql_result_to_tool_response({:error, error_payload}, _query, _variables) do
    tool_failure(error_payload)
  end

  defp graphql_result_to_tool_response(other, _query, _variables) do
    tool_failure(%{
      "type" => "unexpected_result",
      "message" => "Linear GraphQL client returned an unexpected value",
      "result" => inspect(other)
    })
  end

  defp extract_call_arguments(%{"params" => params}) when is_map(params) do
    raw_arguments = Map.get(params, "arguments") || Map.get(params, "input") || params

    case raw_arguments do
      %{} = arguments ->
        query = Map.get(arguments, "query") || Map.get(arguments, :query)
        variables = Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{}
        {:ok, query, variables}

      query when is_binary(query) ->
        {:ok, query, %{}}

      other ->
        {:error,
         %{
           "type" => "invalid_args",
           "message" => "Tool arguments must be a map or a raw query string",
           "value" => inspect(other)
         }}
    end
  end

  defp extract_call_arguments(_message) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "Missing MCP params for tools/call"
     }}
  end

  defp validate_query(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        {:error, %{"type" => "invalid_args", "message" => "query must be a non-empty string"}}

      multiple_operations?(trimmed) ->
        {:error,
         %{
           "type" => "invalid_args",
           "message" => "query must contain exactly one GraphQL operation"
         }}

      true ->
        :ok
    end
  end

  defp validate_query(_query) do
    {:error, %{"type" => "invalid_args", "message" => "query must be a non-empty string"}}
  end

  defp validate_variables(variables) when is_map(variables), do: :ok

  defp validate_variables(_variables) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "variables must be an object when present"
     }}
  end

  defp validate_linear_auth do
    if is_binary(Config.linear_api_token()) do
      :ok
    else
      {:error, %{"type" => "missing_auth", "message" => "LINEAR_API_KEY is not configured"}}
    end
  end

  defp multiple_operations?(query) when is_binary(query) do
    Regex.scan(~r/\b(query|mutation|subscription)\b/i, query)
    |> length()
    |> Kernel.>(1)
  end

  defp tool_definition do
    %{
      "name" => @tool_name,
      "description" => "Execute one Linear GraphQL query or mutation with Rondo's configured Linear auth.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "minLength" => 1,
            "description" => "A single GraphQL query or mutation document"
          },
          "variables" => %{
            "type" => "object",
            "additionalProperties" => true,
            "description" => "Optional GraphQL variables object"
          }
        },
        "required" => ["query"],
        "additionalProperties" => false
      }
    }
  end

  defp tool_success(payload) do
    payload = Map.merge(payload, %{"success" => true, "tool" => @tool_name})
    tool_result(payload, false)
  end

  defp tool_failure(error_payload) do
    tool_result(%{"success" => false, "tool" => @tool_name, "error" => error_payload}, true)
  end

  defp tool_result(payload, is_error) do
    %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
      "isError" => is_error,
      "structuredContent" => payload
    }
  end

  defp jsonrpc_result(message, result) do
    %{
      "jsonrpc" => @jsonrpc_version,
      "id" => Map.get(message, "id"),
      "result" => result
    }
  end

  defp jsonrpc_error(message, code, message_text, data) do
    error = %{
      "code" => code,
      "message" => message_text
    }

    error = Map.put(error, "data", data)

    %{
      "jsonrpc" => @jsonrpc_version,
      "id" => Map.get(message, "id"),
      "error" => error
    }
  end

  defp client_module do
    Application.get_env(:rondo, :linear_client_module, Client)
  end

  defp server_version do
    case Application.spec(:rondo, :vsn) do
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      _ -> @server_version
    end
  end
end
