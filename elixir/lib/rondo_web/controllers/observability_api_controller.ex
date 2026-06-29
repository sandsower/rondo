defmodule RondoWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Rondo observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias Rondo.{ModelUsage, Orchestrator}
  alias RondoWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec submit_guidance(Conn.t(), map()) :: Conn.t()
  def submit_guidance(conn, %{"issue_id" => issue_id, "guidance" => guidance}) do
    case Rondo.Orchestrator.submit_guidance(orchestrator(), issue_id, guidance) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        error_response(conn, 422, "guidance_rejected", inspect(reason))

      :unavailable ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  def submit_guidance(conn, _params) do
    error_response(conn, 400, "invalid_guidance", "issue_id and guidance are required")
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec models(Conn.t(), map()) :: Conn.t()
  def models(conn, _params) do
    case Orchestrator.snapshot(orchestrator(), snapshot_timeout_ms()) do
      %{} = snapshot ->
        running = Map.get(snapshot, :running, [])
        archived = Map.get(snapshot, :archived, [])
        usage = ModelUsage.aggregate(running, archived)
        active_codex = ModelUsage.active_codex_consumers(running)

        # Build per-ticket model timelines
        timelines =
          (running ++ archived)
          |> Enum.group_by(&(&1[:identifier] || &1["identifier"]), & &1)
          |> Enum.map(fn {identifier, runs} ->
            %{
              identifier: identifier,
              timeline: ModelUsage.model_timeline(runs),
              roles: ModelUsage.model_roles(runs)
            }
          end)

        json(conn, %{
          usage: usage,
          active_codex_consumers: active_codex,
          timelines: timelines
        })

      :timeout ->
        error_response(conn, 503, "snapshot_timeout", "Snapshot timed out")

      :unavailable ->
        error_response(conn, 503, "snapshot_unavailable", "Snapshot unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || Rondo.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
