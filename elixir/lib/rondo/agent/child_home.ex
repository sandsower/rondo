defmodule Rondo.Agent.ChildHome do
  @moduledoc """
  Materializes the run-scoped synthetic home described by a child-launch envelope.

  This is an environment hygiene layer, not an OS security boundary.
  """

  alias Rondo.Agent.ChildLaunchEnvelope

  @spec prepare(ChildLaunchEnvelope.t()) :: :ok | {:error, term()}
  def prepare(%ChildLaunchEnvelope{home_path: home_path, environment: environment}) do
    with :ok <- make_private_directory(home_path),
         :ok <- make_private_directory(Map.fetch!(environment, "TMPDIR")) do
      make_private_directory(Map.fetch!(environment, "GH_CONFIG_DIR"))
    end
  end

  @spec port_environment(ChildLaunchEnvelope.t(), map()) :: [{charlist(), charlist() | false}]
  def port_environment(%ChildLaunchEnvelope{environment: environment}, inherited_env \\ System.get_env()) do
    removed = Enum.map(Map.keys(inherited_env), &{String.to_charlist(&1), false})
    allowed = Enum.map(environment, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
    removed ++ allowed
  end

  defp make_private_directory(path) do
    with :ok <- File.mkdir_p(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      File.chmod(path, 0o700)
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:unexpected_child_home_entry, path, type}}
      error -> error
    end
  end
end
