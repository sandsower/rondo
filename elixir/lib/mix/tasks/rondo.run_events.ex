defmodule Mix.Tasks.Rondo.RunEvents do
  use Mix.Task

  alias Rondo.Core.EventFeed

  @moduledoc """
  CLI transport for the `rondo.core/v1` run event feed (`run.events` / `run.status`).

  ## Usage

      mix rondo.run_events --repo-id REPO --run-id RUN [--service-id ID] [--cursor CURSOR]
      mix rondo.run_events --repo-id REPO --run-id RUN --status
      mix rondo.run_events --repo-id REPO --run-id RUN --run-dir PATH

  Prints a single JSON object to stdout:

    * default: the `run.events` response `{"events": [...], "next_event_cursor": "..."}`.
    * `--status`: the `run.status` response `{"run_id", "status", "last_event",
      "evidence_pointers", "event_cursor"}`.

  The feed is read-only and speaks only contract concepts (`service_id`,
  `repo_id`, `run_id`, `event_cursor`); it never mutates the ledger. A consumer
  tails an active run by re-invoking with `--cursor` set to the previous
  `next_event_cursor`, and replays an archived run from an empty/zero cursor.

  `--run-dir` resolves a specific run ledger directly; otherwise the run id is
  located under `--workspace-root` (defaults to `Rondo.Config.workspace_root/0`).
  """
  @shortdoc "Prints the rondo.core/v1 run event feed for a run"

  @switches [
    repo_id: :string,
    run_id: :string,
    service_id: :string,
    cursor: :string,
    run_dir: :string,
    workspace_root: :string,
    status: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: @switches)

    request = %{
      service_id: Keyword.get(opts, :service_id),
      repo_id: Keyword.get(opts, :repo_id),
      run_id: Keyword.get(opts, :run_id),
      event_cursor: Keyword.get(opts, :cursor)
    }

    feed_opts = feed_opts(opts)

    result =
      if Keyword.get(opts, :status, false) do
        EventFeed.run_status(request, feed_opts)
      else
        EventFeed.run_events(request, feed_opts)
      end

    case result do
      {:ok, response} ->
        Mix.shell().info(Jason.encode!(response))

      {:error, reason} ->
        Mix.shell().error(Jason.encode!(%{"error" => inspect(reason)}))
        exit({:shutdown, 1})
    end
  end

  defp feed_opts(opts) do
    opts
    |> Keyword.take([:run_dir, :workspace_root])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
