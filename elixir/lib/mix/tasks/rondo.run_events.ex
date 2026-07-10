defmodule Mix.Tasks.Rondo.RunEvents do
  use Mix.Task

  alias Rondo.Core.EventFeed

  @moduledoc """
  CLI transport for the `rondo.core/v1` run event feed (`run.events` / `run.status`).

  ## Usage

      mix rondo.run_events --repo-id REPO --run-id RUN [--service-id ID] [--cursor CURSOR]
      mix rondo.run_events --repo-id REPO --run-id RUN --status

  Prints a single JSON object to stdout:

    * default: the `run.events` response `{"events": [...], "next_event_cursor": "..."}`.
    * `--status`: the `run.status` response `{"run_id", "status", "last_event",
      "evidence_pointers", "event_cursor"}`.

  The feed is read-only and speaks only contract concepts (`service_id`,
  `repo_id`, `run_id`, `event_cursor`); it never mutates the ledger. A consumer
  tails an active run by re-invoking with `--cursor` set to the previous
  `next_event_cursor`, and replays an archived run from an empty/zero cursor.

  The exact repository and run identity is located under `--workspace-root`
  (defaults to `Rondo.Config.workspace_root/0`).
  """
  @shortdoc "Prints the rondo.core/v1 run event feed for a run"

  @switches [
    repo_id: :string,
    run_id: :string,
    service_id: :string,
    cursor: :string,
    workspace_root: :string,
    status: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    case parse_options(argv) do
      {:ok, opts} -> run_with_options(opts)
      {:error, reason} -> fail(reason)
    end
  end

  defp run_with_options(opts) do
    with {:ok, repo_id} <- required_option(opts, :repo_id, :missing_repo_id),
         {:ok, run_id} <- required_option(opts, :run_id, :missing_run_id) do
      request = %{
        service_id: Keyword.get(opts, :service_id),
        repo_id: repo_id,
        run_id: run_id,
        event_cursor: Keyword.get(opts, :cursor)
      }

      feed_opts = feed_opts(opts)

      result =
        if Keyword.get(opts, :status, false) do
          EventFeed.run_status(request, feed_opts)
        else
          EventFeed.run_events(request, feed_opts)
        end

      render_result(result)
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp render_result(result) do
    case result do
      {:ok, response} ->
        Mix.shell().info(Jason.encode!(response))

      {:error, reason} ->
        fail(reason)
    end
  end

  defp parse_options(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> {:ok, opts}
      {_opts, _arguments, _invalid} -> {:error, :invalid_options}
    end
  end

  defp required_option(opts, key, missing_error) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, missing_error}, else: {:ok, value}

      _other ->
        {:error, missing_error}
    end
  end

  defp fail(reason) do
    Mix.shell().error(Jason.encode!(%{"error" => inspect(reason)}))
    exit({:shutdown, 1})
  end

  defp feed_opts(opts) do
    opts
    |> Keyword.take([:workspace_root])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
