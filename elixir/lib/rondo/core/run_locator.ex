defmodule Rondo.Core.RunLocator do
  @moduledoc """
  Resolves externally supplied Rondo run identities against durable run manifests.

  The locator scans the fixed ledger layout below the configured workspace root.
  Caller-provided identifiers are compared only with stored manifest values and
  are never interpolated into filesystem paths or glob patterns.
  """

  alias Rondo.{Config, PathSafety, RunLedger}

  @max_repo_id_bytes 512
  @max_run_id_bytes 512
  @control_character_pattern ~r/[\x00-\x1F\x7F-\x9F]/u
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @type located_run :: %{run_dir: Path.t(), manifest: map()}

  @doc "Locates one exact `{repo_id, run_id}` pair from its durable manifest."
  @spec locate(term(), term(), keyword()) ::
          {:ok, located_run()} | {:error, term()}
  def locate(repo_id, run_id, opts \\ []) do
    with :ok <- validate_identifier(repo_id, :repo_id),
         :ok <- validate_identifier(run_id, :run_id),
         {:ok, runs} <- durable_runs(opts) do
      case Enum.find(runs, &exact_run?(&1.manifest, repo_id, run_id)) do
        nil -> {:error, :run_not_found}
        located -> {:ok, located}
      end
    end
  end

  @doc "Finds an accepted execution request for a repository and source-contract SHA-256."
  @spec find_accepted_by_source_sha256(term(), term(), keyword()) ::
          {:ok, located_run() | nil} | {:error, term()}
  def find_accepted_by_source_sha256(repo_id, sha256, opts \\ []) do
    with :ok <- validate_identifier(repo_id, :repo_id),
         :ok <- validate_sha256(sha256),
         {:ok, runs} <- durable_runs(Keyword.put(opts, :strict, true)) do
      {:ok,
       Enum.find(
         runs,
         &accepted_source_contract?(&1.manifest, repo_id, sha256)
       )}
    end
  end

  @doc "Lists valid manifests under the fixed durable run-ledger root."
  @spec list_durable_runs(keyword()) :: {:ok, [located_run()]} | {:error, term()}
  def list_durable_runs(opts \\ []), do: durable_runs(opts)

  defp durable_runs(opts) do
    workspace_root = Keyword.get(opts, :workspace_root, Config.workspace_root())
    strict? = Keyword.get(opts, :strict, false)

    with true <- is_binary(workspace_root),
         {:ok, canonical_root} <- PathSafety.canonicalize(workspace_root),
         {:ok, identifier_dirs} <-
           list_directories(Path.join(canonical_root, ".rondo_runs"), strict?),
         {:ok, run_dirs} <- list_nested_directories(identifier_dirs, strict?),
         {:ok, runs} <- load_runs(run_dirs, strict?) do
      {:ok, Enum.sort_by(runs, & &1.run_dir)}
    else
      false -> {:error, :invalid_workspace_root}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_nested_directories(parent_dirs, strict?) do
    Enum.reduce_while(parent_dirs, {:ok, []}, fn parent, {:ok, acc} ->
      case list_directories(parent, strict?) do
        {:ok, dirs} -> {:cont, {:ok, dirs ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp list_directories(path, strict?) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> list_directory_entries(path, strict?)
      {:ok, _stat} -> {:error, {:run_ledger_unreadable, path, :not_directory}}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:run_ledger_unreadable, path, reason}}
    end
  end

  defp list_directory_entries(path, strict?) do
    case File.ls(path) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, directories} ->
          classify_directory_entry(
            Path.join(path, name),
            directories,
            strict?
          )
        end)
        |> reverse_directories()

      {:error, reason} ->
        {:error, {:run_ledger_unreadable, path, reason}}
    end
  end

  defp classify_directory_entry(path, directories, strict?) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:cont, {:ok, [path | directories]}}

      {:ok, %File.Stat{type: :symlink}} when strict? ->
        {:halt, {:error, {:run_ledger_symlink, path}}}

      {:ok, _stat} ->
        {:cont, {:ok, directories}}

      {:error, reason} when strict? ->
        {:halt, {:error, {:run_ledger_unreadable, path, reason}}}

      {:error, _reason} ->
        {:cont, {:ok, directories}}
    end
  end

  defp reverse_directories({:ok, directories}),
    do: {:ok, Enum.reverse(directories)}

  defp reverse_directories(error), do: error

  defp load_runs(run_dirs, strict?) do
    Enum.reduce_while(run_dirs, {:ok, []}, fn run_dir, {:ok, runs} ->
      case load_run(run_dir) do
        {:ok, run} -> {:cont, {:ok, [run | runs]}}
        :skip -> {:cont, {:ok, runs}}
        {:error, _reason} when not strict? -> {:cont, {:ok, runs}}
        {:error, reason} -> {:halt, {:error, {:invalid_run_ledger, run_dir, reason}}}
      end
    end)
  end

  defp load_run(run_dir) do
    manifest_path = Path.join(run_dir, "manifest.json")

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(manifest_path),
         {:ok, ledger} <- RunLedger.open_run(run_dir) do
      {:ok, %{run_dir: ledger.run_dir, manifest: ledger.manifest}}
    else
      {:error, :enoent} -> :skip
      {:ok, %File.Stat{type: type}} -> {:error, {:manifest_not_regular, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_run?(manifest, repo_id, run_id) do
    Map.get(manifest, "run_id") == run_id and stored_repo_id(manifest) == repo_id
  end

  defp accepted_source_contract?(manifest, repo_id, sha256) do
    Map.get(manifest, "source") == "execution_request" and
      get_in(manifest, ["admission", "phase"]) == "accepted" and
      stored_repo_id(manifest) == repo_id and
      get_in(manifest, ["admission", "repo_id"]) == repo_id and
      get_in(manifest, ["admission", "manifest_sha256"]) == sha256 and
      get_in(manifest, ["source_contract", "sha256"]) == sha256
  end

  defp stored_repo_id(manifest), do: get_in(manifest, ["repo", "repo_id"])

  defp validate_identifier(nil, field), do: {:error, missing_error(field)}

  defp validate_identifier(value, field) when is_binary(value) do
    if String.valid?(value) and value == String.trim(value) and value != "" and
         byte_size(value) <= identifier_limit(field) and
         not Regex.match?(@control_character_pattern, value) do
      :ok
    else
      {:error, invalid_error(field)}
    end
  end

  defp validate_identifier(_value, field), do: {:error, invalid_error(field)}

  defp validate_sha256(nil), do: {:error, :missing_source_contract_sha256}

  defp validate_sha256(value) when is_binary(value) do
    if Regex.match?(@sha256_pattern, value),
      do: :ok,
      else: {:error, :invalid_source_contract_sha256}
  end

  defp validate_sha256(_value), do: {:error, :invalid_source_contract_sha256}

  defp missing_error(:repo_id), do: :missing_repo_id
  defp missing_error(:run_id), do: :missing_run_id
  defp invalid_error(:repo_id), do: :invalid_repo_id
  defp invalid_error(:run_id), do: :invalid_run_id
  defp identifier_limit(:repo_id), do: @max_repo_id_bytes
  defp identifier_limit(:run_id), do: @max_run_id_bytes
end
