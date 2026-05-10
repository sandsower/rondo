defmodule Rondo.GitHub.Client do
  @moduledoc """
  GitHub Issues client backed by the `gh` CLI.
  """

  require Logger

  alias Rondo.{Config, Linear.Issue}

  @json_fields "number,title,body,labels,url,state,createdAt,updatedAt"
  @default_limit "100"
  @state_label_color "5319E7"

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    with {:ok, context} <- context(opts),
         {:ok, raw_issues} <- list_issues(context, "open") do
      active_states = normalize_states(Keyword.get_lazy(opts, :active_states, &Config.tracker_active_states/0))

      issues =
        raw_issues
        |> Enum.map(&normalize_issue(&1, context.repo, context.state_label_prefix))
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn %Issue{state: state} -> MapSet.member?(active_states, normalize_state(state)) end)

      {:ok, issues}
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states, opts \\ []) when is_list(states) do
    states
    |> normalize_states()
    |> do_fetch_issues_by_states(opts)
  end

  defp do_fetch_issues_by_states(wanted_states, opts) do
    case MapSet.size(wanted_states) do
      0 -> fetch_no_issues()
      _ -> fetch_issues_matching_states(wanted_states, opts)
    end
  end

  defp fetch_no_issues, do: {:ok, []}

  defp fetch_issues_matching_states(wanted_states, opts) do
    with {:ok, context} <- context(opts),
         {:ok, raw_issues} <- list_issues(context, "all") do
      {:ok, filter_issues_by_states(raw_issues, context, wanted_states)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) do
    issue_ids
    |> Enum.uniq()
    |> do_fetch_issue_states_by_ids(opts)
  end

  defp do_fetch_issue_states_by_ids([], _opts), do: {:ok, []}

  defp do_fetch_issue_states_by_ids(ids, opts) do
    with {:ok, context} <- context(opts) do
      view_issues_by_id(ids, context)
    end
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, opts \\ []) when is_binary(issue_id) and is_binary(body) do
    with {:ok, context} <- context(opts),
         {:ok, number} <- parse_issue_number(issue_id, context.repo) do
      body_file = Path.join(System.tmp_dir!(), "rondo-github-comment-#{System.unique_integer([:positive])}.md")

      try do
        File.write!(body_file, body)

        case run_gh(context, ["issue", "comment", number, "--repo", context.repo, "--body-file", body_file]) do
          {:ok, _output} -> :ok
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm(body_file)
      end
    end
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, opts \\ []) when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, context} <- context(opts),
         {:ok, number} <- parse_issue_number(issue_id, context.repo),
         {:ok, raw_issue} <- view_raw_issue(context, number),
         :ok <- ensure_state_label(context, state_name) do
      target_label = state_label(context.state_label_prefix, state_name)

      old_state_labels =
        raw_issue
        |> label_names()
        |> Enum.filter(&state_label?(&1, context.state_label_prefix))
        |> Enum.reject(&(&1 == target_label))

      with :ok <- add_state_label(context, number, target_label) do
        remove_state_labels(context, number, old_state_labels)
      end
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, repo \\ Config.tracker_repo()) when is_map(issue) do
    normalize_issue(issue, repo, Config.tracker_state_label_prefix())
  end

  defp context(opts) do
    repo = Keyword.get_lazy(opts, :repo, &Config.tracker_repo/0)

    if is_binary(repo) and String.trim(repo) != "" do
      {:ok,
       %{
         repo: String.trim(repo),
         runner: Keyword.get(opts, :runner, &System.cmd/3),
         label_filter: Keyword.get_lazy(opts, :label_filter, &Config.tracker_label_filter/0),
         state_label_prefix: Keyword.get_lazy(opts, :state_label_prefix, &Config.tracker_state_label_prefix/0)
       }}
    else
      {:error, :missing_github_repo}
    end
  end

  defp filter_issues_by_states(raw_issues, context, wanted_states) do
    raw_issues
    |> Enum.map(&normalize_issue(&1, context.repo, context.state_label_prefix))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn %Issue{state: state} -> MapSet.member?(wanted_states, normalize_state(state)) end)
  end

  defp view_issues_by_id(ids, context) do
    ids
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, issues} ->
      with {:ok, number} <- parse_issue_number(issue_id, context.repo),
           {:ok, issue} <- view_issue(context, number) do
        {:cont, {:ok, [issue | issues]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_state_labels(context, number, labels) do
    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case run_gh(context, ["issue", "edit", number, "--repo", context.repo, "--remove-label", label]) do
        {:ok, _output} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp add_state_label(context, number, label) do
    case run_gh(context, ["issue", "edit", number, "--repo", context.repo, "--add-label", label]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_issues(context, native_state) do
    args =
      ["issue", "list", "--repo", context.repo, "--state", native_state, "--limit", @default_limit, "--json", @json_fields] ++
        label_args(context.label_filter)

    with {:ok, output} <- run_gh(context, args),
         {:ok, issues} when is_list(issues) <- Jason.decode(output) do
      {:ok, issues}
    else
      {:ok, _payload} -> {:error, :github_unexpected_payload}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:github_decode_failed, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp view_issue(context, number) do
    with {:ok, raw_issue} <- view_raw_issue(context, number) do
      case normalize_issue(raw_issue, context.repo, context.state_label_prefix) do
        %Issue{} = issue -> {:ok, issue}
        nil -> {:error, {:github_issue_state_unreadable, "#{context.repo}##{number}"}}
      end
    end
  end

  defp view_raw_issue(context, number) do
    with {:ok, output} <- run_gh(context, ["issue", "view", number, "--repo", context.repo, "--json", @json_fields]),
         {:ok, issue} when is_map(issue) <- Jason.decode(output) do
      {:ok, issue}
    else
      {:ok, _payload} -> {:error, :github_unexpected_payload}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:github_decode_failed, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_state_label(context, state_name) do
    target_label = state_label(context.state_label_prefix, state_name)

    case run_gh(context, [
           "label",
           "create",
           target_label,
           "--repo",
           context.repo,
           "--color",
           @state_label_color,
           "--description",
           "Rondo workflow state: #{state_name}"
         ]) do
      {:ok, _output} -> :ok
      {:error, {:github_cli_failed, _args, _status, output}} -> tolerate_existing_label(output)
      {:error, reason} -> {:error, reason}
    end
  end

  defp tolerate_existing_label(output) do
    if output |> to_string() |> String.downcase() |> String.contains?("already exists") do
      :ok
    else
      {:error, {:github_label_create_failed, output}}
    end
  end

  defp run_gh(context, args) do
    case context.runner.("gh", args, stderr_to_stdout: true) do
      {:error, :enoent} -> {:error, :missing_github_cli}
      {:error, reason} -> {:error, {:github_cli_error, reason}}
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, map_cli_error(context.repo, args, status, output)}
    end
  rescue
    error in ErlangError ->
      case Map.get(error, :original) do
        :enoent -> {:error, :missing_github_cli}
        reason -> {:error, {:github_cli_error, reason}}
      end
  end

  defp map_cli_error(repo, args, status, output) do
    normalized = output |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, "gh auth login") or String.contains?(normalized, "not logged") or
        String.contains?(normalized, "authentication") or String.contains?(normalized, "bad credentials") ->
        {:github_auth_failed, output}

      String.contains?(normalized, "could not resolve to a repository") or
        String.contains?(normalized, "repository not found") or String.contains?(normalized, "not found") ->
        {:github_repo_unavailable, repo, output}

      true ->
        {:github_cli_failed, args, status, output}
    end
  end

  defp normalize_issue(issue, repo, state_label_prefix) when is_map(issue) do
    number = issue["number"]

    with true <- not is_nil(number),
         {:ok, state} <- issue_state(issue, state_label_prefix) do
      number_string = to_string(number)

      %Issue{
        id: "#{repo}##{number_string}",
        identifier: "GH-#{number_string}",
        title: issue["title"],
        description: issue["body"],
        priority: nil,
        state: state,
        branch_name: nil,
        url: issue["url"],
        labels: label_names(issue),
        blocked_by: [],
        assigned_to_worker: true,
        created_at: parse_datetime(issue["createdAt"]),
        updated_at: parse_datetime(issue["updatedAt"])
      }
    else
      _ -> nil
    end
  end

  defp normalize_issue(_issue, _repo, _state_label_prefix), do: nil

  defp issue_state(issue, state_label_prefix) do
    state_labels = issue |> label_names() |> Enum.filter(&state_label?(&1, state_label_prefix))

    case state_labels do
      [label] ->
        {:ok, label_state(label, state_label_prefix)}

      [] ->
        native_closed_state(issue["state"])

      labels ->
        Logger.warning("Skipping GitHub issue with multiple state labels: labels=#{inspect(labels)}")
        :error
    end
  end

  defp native_closed_state(state) when is_binary(state) do
    if String.downcase(state) == "closed", do: {:ok, "Closed"}, else: :error
  end

  defp native_closed_state(_state), do: :error

  defp label_names(issue) do
    issue
    |> Map.get("labels", [])
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp state_label?(label, prefix) when is_binary(label) and is_binary(prefix), do: String.starts_with?(label, prefix)
  defp state_label?(_label, _prefix), do: false

  defp label_state(label, prefix) do
    label
    |> String.replace_prefix(prefix, "")
    |> String.trim()
  end

  defp state_label(prefix, state_name) do
    trimmed_prefix = String.trim_trailing(prefix)
    trimmed_state = String.trim(state_name)

    cond do
      String.ends_with?(trimmed_prefix, ":") -> trimmed_prefix <> " " <> trimmed_state
      String.ends_with?(trimmed_prefix, " ") -> trimmed_prefix <> trimmed_state
      true -> trimmed_prefix <> trimmed_state
    end
  end

  defp parse_issue_number(issue_id, repo) do
    prefix = repo <> "#"

    cond do
      not is_binary(issue_id) ->
        {:error, {:invalid_github_issue_id, issue_id}}

      String.starts_with?(issue_id, prefix) ->
        number = String.replace_prefix(issue_id, prefix, "")

        if number =~ ~r/^\d+$/ do
          {:ok, number}
        else
          {:error, {:invalid_github_issue_id, issue_id}}
        end

      String.contains?(issue_id, "#") ->
        {:error, {:github_issue_repo_mismatch, issue_id, repo}}

      issue_id =~ ~r/^\d+$/ ->
        {:ok, issue_id}

      true ->
        {:error, {:invalid_github_issue_id, issue_id}}
    end
  end

  defp label_args(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn label -> ["--label", label] end)
  end

  defp label_args(_labels), do: []

  defp normalize_states(states) do
    states
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&normalize_state/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
