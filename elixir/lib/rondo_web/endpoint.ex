defmodule RondoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :rondo

  alias Plug.Conn

  @loopback_required_body ~s({"error":{"code":"loopback_required","message":"Rondo Core API is available only to loopback callers"}})
  @invalid_core_json_body ~s({"error":{"code":"invalid_request","message":"request body must contain valid JSON"}})
  @parser_options Plug.Parsers.init(
                    parsers: [:urlencoded, :multipart, :json],
                    pass: ["*/*"],
                    json_decoder: Jason
                  )

  @session_options [
    store: :cookie,
    key: "_rondo_key",
    signing_salt: "rondo-session"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(:reject_remote_core_request)

  plug(:parse_request_body)

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(RondoWeb.Router)

  @doc false
  @spec reject_remote_core_request(Conn.t(), keyword()) :: Conn.t()
  def reject_remote_core_request(conn, _opts) do
    if core_api_route?(conn) and not loopback?(conn.remote_ip) do
      conn
      |> Conn.put_resp_content_type("application/json")
      |> Conn.send_resp(403, @loopback_required_body)
      |> Conn.halt()
    else
      conn
    end
  end

  @doc false
  @spec parse_request_body(Conn.t(), keyword()) :: Conn.t()
  def parse_request_body(conn, _opts) do
    Plug.Parsers.call(conn, @parser_options)
  rescue
    error in Plug.Parsers.ParseError ->
      if core_api_route?(conn) and json_content_type?(conn) do
        conn
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(400, @invalid_core_json_body)
        |> Conn.halt()
      else
        reraise error, __STACKTRACE__
      end
  end

  defp core_api_route?(%Conn{path_info: ["api", "v1", "execution-requests"]}), do: true
  defp core_api_route?(%Conn{path_info: ["api", "v1", "runs", run_id]}) when run_id != "", do: true

  defp core_api_route?(%Conn{path_info: ["api", "v1", "runs", run_id, "events"]})
       when run_id != "",
       do: true

  defp core_api_route?(_conn), do: false

  defp json_content_type?(conn) do
    conn
    |> Conn.get_req_header("content-type")
    |> Enum.any?(fn content_type ->
      media_type =
        content_type
        |> String.split(";", parts: 2)
        |> List.first()
        |> String.trim()
        |> String.downcase()

      media_type == "application/json" or String.ends_with?(media_type, "+json")
    end)
  end

  defp loopback?({127, second, third, fourth})
       when second in 0..255 and third in 0..255 and fourth in 0..255,
       do: true

  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_remote_ip), do: false
end
