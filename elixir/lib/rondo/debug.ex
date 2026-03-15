defmodule Rondo.Debug do
  @moduledoc """
  Debug logging for Rondo. Writes to a log file when debug mode is enabled.
  Enable via `--debug` CLI flag or `Rondo.Config.set_debug(true)`.
  """

  @log_filename "rondo_debug.log"

  @log_fallback "/tmp/rondo_debug.log"

  @spec log(String.t()) :: :ok
  def log(msg) do
    if Rondo.Config.debug?() do
      line = "[#{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}] #{msg}\n"

      path =
        try do
          log_path()
        rescue
          _ -> @log_fallback
        end

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, line, [:append])
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec log_path() :: Path.t()
  def log_path do
    Path.join(workspace_root(), @log_filename)
  end

  defp workspace_root do
    Rondo.Config.workspace_root()
  rescue
    _ -> Path.join(System.tmp_dir!(), "rondo_workspaces")
  end
end
