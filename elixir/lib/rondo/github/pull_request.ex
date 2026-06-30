defmodule Rondo.GitHub.PullRequest do
  @moduledoc """
  GitHub pull request helper backed by the `gh` CLI.
  """

  @pr_list_fields "number,url,title,state,headRefName,baseRefName,isDraft,mergeable,mergeStateStatus,reviewDecision"
  @pr_view_fields "number,url,title,state,headRefName,baseRefName,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,reviews,comments"

  @spec find_open_by_branch(String.t(), String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def find_open_by_branch(repo, branch, opts \\ []) when is_binary(repo) and is_binary(branch) do
    with {:ok, output} <- run_gh(opts, ["pr", "list", "--repo", repo, "--head", branch, "--state", "open", "--json", @pr_list_fields]),
         {:ok, prs} when is_list(prs) <- Jason.decode(output) do
      {:ok, List.first(prs)}
    else
      {:ok, _payload} -> {:error, :github_unexpected_payload}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:github_decode_failed, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec view(String.t() | integer(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def view(number, repo, opts \\ []) when is_binary(repo) do
    with {:ok, output} <- run_gh(opts, ["pr", "view", to_string(number), "--repo", repo, "--json", @pr_view_fields]),
         {:ok, pr} when is_map(pr) <- Jason.decode(output) do
      {:ok, pr}
    else
      {:ok, _payload} -> {:error, :github_unexpected_payload}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:github_decode_failed, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec inline_comments(String.t() | integer(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def inline_comments(number, repo, opts \\ []) when is_binary(repo) do
    with {:ok, output} <- run_gh(opts, ["api", "repos/#{repo}/pulls/#{number}/comments"]),
         {:ok, comments} when is_list(comments) <- Jason.decode(output) do
      {:ok, comments}
    else
      {:ok, _payload} -> {:error, :github_unexpected_payload}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:github_decode_failed, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reply_comment(String.t() | integer(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def reply_comment(_number, comment_id, body, opts \\ []) when is_binary(comment_id) and is_binary(body) do
    repo = Keyword.fetch!(opts, :repo)

    with {:ok, output} <-
           run_gh(opts, [
             "api",
             "repos/#{repo}/pulls/comments/#{comment_id}/replies",
             "--method",
             "POST",
             "--field",
             "body=#{body}"
           ]) do
      case output do
        _ -> :ok
      end
    end
  end

  @spec ready(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  def ready(number, opts \\ []) do
    repo = Keyword.fetch!(opts, :repo)

    case run_gh(opts, ["pr", "ready", to_string(number), "--repo", repo]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec merge(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  def merge(number, opts \\ []) do
    repo = Keyword.fetch!(opts, :repo)
    method = Keyword.get(opts, :method, "merge")
    delete_branch? = Keyword.get(opts, :delete_branch, true)

    args = ["pr", "merge", to_string(number), "--repo", repo, merge_flag(method)] ++ merge_delete_branch_args(delete_branch?)

    case run_gh(opts, args) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec current_repo(keyword()) :: {:ok, String.t()} | {:error, term()}
  def current_repo(opts \\ []) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) ->
        trimmed = String.trim(repo)

        if trimmed == "" do
          {:error, :missing_github_repo}
        else
          {:ok, trimmed}
        end

      _ ->
        {:error, :missing_github_repo}
    end
  end

  defp merge_flag("merge"), do: "--merge"
  defp merge_flag("squash"), do: "--squash"
  defp merge_flag("rebase"), do: "--rebase"
  defp merge_flag(_), do: "--merge"

  defp merge_delete_branch_args(true), do: ["--delete-branch"]
  defp merge_delete_branch_args(false), do: []

  defp run_gh(opts, args) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    case runner.("gh", args, stderr_to_stdout: true) do
      {:error, :enoent} -> {:error, :missing_github_cli}
      {:error, reason} -> {:error, {:github_cli_error, reason}}
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:github_cli_failed, args, status, output}}
    end
  rescue
    error in ErlangError ->
      case Map.get(error, :original) do
        :enoent -> {:error, :missing_github_cli}
        reason -> {:error, {:github_cli_error, reason}}
      end
  end
end
