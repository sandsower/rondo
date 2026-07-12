defmodule RondoWeb.CoreApiController do
  @moduledoc """
  HTTP transport for the provisional `rondo.core/v1` run contract.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias Rondo.Core.EventFeed
  alias RondoWeb.Endpoint

  @surface "rondo.core/v1"
  @max_identifier_bytes 512
  @control_character_pattern ~r/[\x00-\x1F\x7F-\x9F]/u
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @instance_id_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @spec health(Conn.t(), map()) :: Conn.t()
  def health(conn, _params) do
    loopback_only(conn, fn -> do_health(conn) end)
  end

  @spec submit_execution_request(Conn.t(), map()) :: Conn.t()
  def submit_execution_request(conn, params) do
    loopback_only(conn, fn -> do_submit_execution_request(conn, params) end)
  end

  @spec run_status(Conn.t(), map()) :: Conn.t()
  def run_status(conn, %{"run_id" => run_id} = params) do
    loopback_only(conn, fn -> do_run_status(conn, run_id, params) end)
  end

  @spec run_events(Conn.t(), map()) :: Conn.t()
  def run_events(conn, %{"run_id" => run_id} = params) do
    loopback_only(conn, fn -> do_run_events(conn, run_id, params) end)
  end

  defp do_submit_execution_request(conn, params) do
    case execution_request(params) do
      {:ok, request} -> submit_request(conn, request)
      {:error, :invalid_request} -> submit_error(conn, :invalid_request)
    end
  end

  defp do_health(conn) do
    identity = core_identity().snapshot(core_orchestrator())

    with true <- exact_required_echo?(identity, :surface, @surface),
         {:ok, runtime_version} <- nonempty_response_string(identity, :runtime_version),
         {:ok, instance_id} <- nonempty_response_string(identity, :instance_id),
         true <- Regex.match?(@instance_id_pattern, instance_id),
         {:ok, service_mode} <- nonempty_response_string(identity, :service_mode),
         true <- service_mode in ["trackerless_core", "tracker_daemon"],
         {:ok, ready} <- fetch_value(identity, :ready),
         true <- is_boolean(ready),
         {:ok, active_run_count} <- fetch_value(identity, :active_run_count),
         true <- is_integer(active_run_count) and active_run_count >= 0 do
      json(conn, %{
        "surface" => @surface,
        "runtime_version" => runtime_version,
        "instance_id" => instance_id,
        "service_mode" => service_mode,
        "ready" => ready,
        "active_run_count" => active_run_count
      })
    else
      _invalid -> feed_error(conn, :unavailable)
    end
  end

  defp do_run_status(conn, run_id, params) do
    with {:ok, run_id} <- required_identifier(run_id),
         {:ok, repo_id} <- required_repo_id(params, "repo_id") do
      fetch_run_status(conn, core_run_request(run_id, repo_id, nil))
    else
      {:error, :invalid_request} -> feed_error(conn, :invalid_request)
    end
  end

  defp do_run_events(conn, run_id, params) do
    with {:ok, run_id} <- required_identifier(run_id),
         {:ok, repo_id} <- required_repo_id(params, "repo_id"),
         {:ok, cursor} <- optional_cursor(params, "cursor") do
      request = core_run_request(run_id, repo_id, cursor)
      fetch_run_events(conn, request)
    else
      {:error, :invalid_request} -> feed_error(conn, :invalid_request)
    end
  end

  defp loopback_only(conn, callback) do
    if loopback?(conn.remote_ip) do
      callback.()
    else
      error_response(conn, 403, "loopback_required", "Rondo Core API is available only to loopback callers")
    end
  end

  defp loopback?({127, second, third, fourth})
       when second in 0..255 and third in 0..255 and fourth in 0..255,
       do: true

  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_remote_ip), do: false

  defp execution_request(params) do
    with {:ok, manifest_path} <- required_string(params, "manifest_path"),
         {:ok, manifest_sha256} <- required_digest(params, "manifest_sha256"),
         {:ok, repo_id} <- required_repo_id(params, "repo_id") do
      {:ok,
       %{
         manifest_path: manifest_path,
         manifest_sha256: manifest_sha256,
         repo_id: repo_id
       }}
    end
  end

  defp submit_request(conn, request) do
    case core_orchestrator().submit_execution_request(orchestrator(), request) do
      {:ok, run} when is_map(run) -> submit_success(conn, run, request.repo_id)
      {:error, reason} -> submit_error(conn, reason)
      :unavailable -> submit_error(conn, :unavailable)
      _other -> submit_error(conn, :unavailable)
    end
  end

  defp fetch_run_status(conn, request) do
    case core_event_feed().run_status(request) do
      {:ok, response} when is_map(response) -> render_run_status(conn, request, response)
      {:error, reason} -> feed_error(conn, reason)
      :unavailable -> feed_error(conn, :unavailable)
      _other -> feed_error(conn, :unavailable)
    end
  end

  defp fetch_run_events(conn, request) do
    case core_event_feed().run_events(request) do
      {:ok, response} when is_map(response) -> render_run_events(conn, request, response)
      {:error, reason} -> feed_error(conn, reason)
      :unavailable -> feed_error(conn, :unavailable)
      _other -> feed_error(conn, :unavailable)
    end
  end

  defp required_digest(params, key) do
    with {:ok, value} <- required_string(params, key),
         true <- Regex.match?(@sha256_pattern, value) do
      {:ok, value}
    else
      _other -> {:error, :invalid_request}
    end
  end

  defp required_string(params, key) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :invalid_request}
          _nonblank -> {:ok, value}
        end

      _other ->
        {:error, :invalid_request}
    end
  end

  defp required_repo_id(params, key) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        required_identifier(value)

      _other ->
        {:error, :invalid_request}
    end
  end

  defp required_identifier(value) when is_binary(value) do
    if String.valid?(value) and value != "" and value == String.trim(value) and
         byte_size(value) <= @max_identifier_bytes and
         not Regex.match?(@control_character_pattern, value) do
      {:ok, value}
    else
      {:error, :invalid_request}
    end
  end

  defp required_identifier(_value), do: {:error, :invalid_request}

  defp optional_string(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, :invalid_request}
    end
  end

  defp optional_cursor(params, key) do
    with {:ok, cursor} <- optional_string(params, key),
         {:ok, _offset} <- EventFeed.parse_cursor(cursor) do
      {:ok, cursor}
    else
      _other -> {:error, :invalid_request}
    end
  end

  defp submit_success(conn, run, repo_id) do
    with true <- exact_required_echo?(run, :surface, @surface),
         true <- exact_required_echo?(run, :repo_id, repo_id),
         {:ok, service_id} <- nonempty_response_string(run, :service_id),
         {:ok, run_id} <- nonempty_response_string(run, :run_id),
         {:ok, status_value} <- nonempty_response_string(run, :status),
         {:ok, event_cursor} <- response_cursor(run, :event_cursor),
         {:ok, deduplicated} <- fetch_value(run, :deduplicated),
         true <- is_boolean(deduplicated) do
      response = %{
        "surface" => @surface,
        "service_id" => service_id,
        "repo_id" => repo_id,
        "run_id" => run_id,
        "status" => status_value,
        "event_cursor" => event_cursor,
        "deduplicated" => deduplicated
      }

      http_status = if deduplicated, do: 200, else: 202

      conn
      |> put_status(http_status)
      |> json(response)
    else
      _invalid -> submit_error(conn, :unavailable)
    end
  end

  defp render_run_status(conn, request, response) do
    with true <- exact_required_echo?(response, :run_id, request.run_id),
         true <- exact_required_echo?(response, :repo_id, request.repo_id),
         true <- exact_required_echo?(response, :surface, @surface),
         {:ok, status} <- nonempty_response_string(response, :status),
         {:ok, last_event} <- fetch_value(response, :last_event),
         true <- is_nil(last_event) or is_map(last_event),
         {:ok, evidence_pointers} <- fetch_value(response, :evidence_pointers),
         true <- is_list(evidence_pointers),
         {:ok, event_cursor} <- response_cursor(response, :event_cursor) do
      json(conn, %{
        "surface" => @surface,
        "repo_id" => request.repo_id,
        "run_id" => request.run_id,
        "status" => status,
        "last_event" => last_event,
        "evidence_pointers" => evidence_pointers,
        "event_cursor" => event_cursor
      })
    else
      _invalid -> feed_error(conn, :unavailable)
    end
  end

  defp render_run_events(conn, request, response) do
    with true <- exact_required_echo?(response, :run_id, request.run_id),
         true <- exact_required_echo?(response, :repo_id, request.repo_id),
         true <- exact_required_echo?(response, :surface, @surface),
         {:ok, events} <- fetch_value(response, :events),
         true <- is_list(events),
         {:ok, next_event_cursor} <- response_cursor(response, :next_event_cursor),
         {:ok, has_more} <- fetch_value(response, :has_more),
         true <- is_boolean(has_more) do
      json(conn, %{
        "surface" => @surface,
        "repo_id" => request.repo_id,
        "run_id" => request.run_id,
        "events" => events,
        "next_event_cursor" => next_event_cursor,
        "has_more" => has_more
      })
    else
      _invalid -> feed_error(conn, :unavailable)
    end
  end

  defp submit_error(conn, reason) do
    case error_kind(reason) do
      :invalid_request -> error_response(conn, 400, "invalid_request", "manifest_path, manifest_sha256, and repo_id are required")
      :digest_conflict -> error_response(conn, 409, "digest_conflict", "Manifest digest conflicts with an existing submission")
      :invalid_manifest -> error_response(conn, 422, "invalid_manifest", "Execution request manifest is invalid")
      :unapproved_manifest -> error_response(conn, 422, "unapproved_manifest", "Execution request manifest is not approved")
      :capacity_exhausted -> error_response(conn, 429, "capacity_exhausted", "Rondo Core has no available execution capacity")
      :unavailable -> error_response(conn, 503, "orchestrator_unavailable", "Rondo Core orchestrator is unavailable")
      _unsupported -> error_response(conn, 503, "orchestrator_unavailable", "Rondo Core orchestrator is unavailable")
    end
  end

  defp feed_error(conn, reason) do
    case error_kind(reason) do
      kind when kind in [:invalid_request, :invalid_cursor] ->
        error_response(conn, 400, "invalid_request", "repo_id and cursor must be valid")

      :not_found ->
        error_response(conn, 404, "run_not_found", "Rondo Core run was not found")

      :unavailable ->
        error_response(conn, 503, "core_unavailable", "Rondo Core is unavailable")

      _other ->
        error_response(conn, 503, "core_unavailable", "Rondo Core is unavailable")
    end
  end

  defp error_kind({kind, _detail}) when kind in [:invalid_request, :invalid_cursor, :digest_conflict, :invalid_manifest, :unapproved_manifest, :capacity_exhausted, :not_found],
    do: kind

  defp error_kind({:run_not_found, _detail}), do: :not_found
  defp error_kind(:run_not_found), do: :not_found
  defp error_kind(kind) when kind in [:missing_repo_id, :missing_run_id, :invalid_repo_id, :invalid_run_id], do: :invalid_request
  defp error_kind(kind) when kind in [:invalid_request, :invalid_cursor, :digest_conflict, :invalid_manifest, :unapproved_manifest, :capacity_exhausted, :not_found], do: kind
  defp error_kind(_reason), do: :unavailable

  defp core_run_request(run_id, repo_id, event_cursor) do
    %{
      service_id: service_id(),
      repo_id: repo_id,
      run_id: run_id,
      event_cursor: event_cursor
    }
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp nonempty_response_string(map, key) do
    case fetch_value(map, key) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "", do: :error, else: {:ok, value}

      _invalid ->
        :error
    end
  end

  defp response_cursor(map, key) do
    with {:ok, cursor} <- nonempty_response_string(map, key),
         {:ok, _offset} <- EventFeed.parse_cursor(cursor) do
      {:ok, cursor}
    else
      _invalid -> :error
    end
  end

  defp exact_required_echo?(map, key, expected), do: fetch_value(map, key) == {:ok, expected}

  defp core_orchestrator, do: Endpoint.config(:core_orchestrator) || Rondo.Orchestrator
  defp core_event_feed, do: Endpoint.config(:core_event_feed) || Rondo.Core.EventFeed
  defp core_identity, do: Endpoint.config(:core_identity) || Rondo.Core.Identity
  defp orchestrator, do: Endpoint.config(:orchestrator) || Rondo.Orchestrator
  defp service_id, do: Endpoint.config(:core_service_id) || "rondo-core"
end
