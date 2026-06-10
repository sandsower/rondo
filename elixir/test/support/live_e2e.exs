defmodule Rondo.LiveE2E do
  @moduledoc """
  Orchestration helpers for the opt-in live Linear + Claude end-to-end profile.

  All Linear access goes through an injectable `graphql` function (2-arity:
  query, variables) defaulting to `Rondo.Linear.Client.graphql/2`, so the live
  test reuses Rondo's existing Linear config plumbing while unit tests exercise
  this module with fixture functions.
  """

  require Logger

  alias Rondo.Linear.Client

  @enable_var "RONDO_RUN_LIVE_E2E"
  @required_env ["LINEAR_API_KEY", "RONDO_E2E_LINEAR_TEAM", "RONDO_E2E_LINEAR_PROJECT"]
  @placeholder_api_key "test-linear-api-key"
  @action_policy_override_var "RONDO_E2E_ACTION_POLICY_COMMAND"
  @action_policy_fake_value "fake"
  @title_prefix "[rondo-e2e]"
  @start_state_name "Todo"
  @in_progress_state_name "In Progress"

  @team_query """
  query RondoE2EResolveTeam($key: String!) {
    teams(filter: {key: {eq: $key}}, first: 1) {
      nodes {
        id
        key
        name
        states {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @project_query """
  query RondoE2EResolveProject($name: String!) {
    projects(filter: {name: {eq: $name}}, first: 10) {
      nodes {
        id
        name
        slugId
        teams {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @issue_create_mutation """
  mutation RondoE2ECreateIssue($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        url
        state {
          name
        }
      }
    }
  }
  """

  @issue_state_query """
  query RondoE2EIssueState($id: String!) {
    issue(id: $id) {
      id
      identifier
      state {
        name
      }
    }
  }
  """

  @issue_delete_mutation """
  mutation RondoE2EDeleteIssue($id: String!) {
    issueDelete(id: $id) {
      success
    }
  }
  """

  @spec enabled?((String.t() -> String.t() | nil)) :: boolean()
  def enabled?(env \\ &System.get_env/1) do
    env.(@enable_var) == "1"
  end

  @spec skip_reason() :: String.t()
  def skip_reason do
    "live E2E disabled: set #{@enable_var}=1 (plus #{Enum.join(@required_env, ", ")}) " <>
      "to run the live Linear + Claude profile; see README \"Live end-to-end test\""
  end

  @spec title_prefix() :: String.t()
  def title_prefix, do: @title_prefix

  @spec start_state_name() :: String.t()
  def start_state_name, do: @start_state_name

  @spec in_progress_state_name() :: String.t()
  def in_progress_state_name, do: @in_progress_state_name

  @doc """
  Validates required live-run environment and returns the run context.

  Returns `{:error, {:missing_env, names}}` listing every missing variable,
  `{:error, :placeholder_linear_api_key}` when the test-suite placeholder key
  is still in place, or `{:error, {:action_policy_command_missing, var}}` when
  `beislid` is not installed and no explicit override is set.

  ### Action-policy resolution

  The live profile is fail-closed on action-policy by default:

  1. If `#{@action_policy_override_var}` is set to `"#{@action_policy_fake_value}"`, the
     allow-all `TestSupport` stub is used — an explicit, auditable opt-in.
  2. If `#{@action_policy_override_var}` is set to any other value, that path is
     used as the evaluator command directly.
  3. Otherwise `beislid` is probed on `$PATH`. If found, it is used with no env
     var required. If absent, context loading **fails** with
     `{:error, {:action_policy_command_missing, "#{@action_policy_override_var}"}}` and
     a clear message so the caller can decide whether to opt in to the fake.

  The resolved value is stored as `:fake` (atom) when the stub is requested, or
  as a binary command path otherwise.
  """
  @spec load_context((String.t() -> String.t() | nil)) :: {:ok, map()} | {:error, term()}
  def load_context(env \\ &System.get_env/1) do
    load_context(env, &System.find_executable/1)
  end

  @spec load_context(
          (String.t() -> String.t() | nil),
          (String.t() -> String.t() | nil)
        ) :: {:ok, map()} | {:error, term()}
  def load_context(env, find_executable) do
    missing = Enum.filter(@required_env, &blank?(env.(&1)))

    cond do
      missing != [] ->
        {:error, {:missing_env, missing}}

      env.("LINEAR_API_KEY") == @placeholder_api_key ->
        {:error, :placeholder_linear_api_key}

      true ->
        case resolve_action_policy_command(env.(@action_policy_override_var), find_executable) do
          {:ok, action_policy_command} ->
            {:ok,
             %{
               team_key: env.("RONDO_E2E_LINEAR_TEAM"),
               project_name: env.("RONDO_E2E_LINEAR_PROJECT"),
               claude_command: env.("RONDO_E2E_CLAUDE_COMMAND") || "claude",
               claude_max_turns: parse_max_turns(env.("RONDO_E2E_CLAUDE_MAX_TURNS")),
               action_policy_command: action_policy_command
             }}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Returns the name of the env var used to override the action-policy command.
  """
  @spec action_policy_override_var() :: String.t()
  def action_policy_override_var, do: @action_policy_override_var

  @doc """
  Returns the sentinel value that opts in to the allow-all fake evaluator.
  """
  @spec action_policy_fake_value() :: String.t()
  def action_policy_fake_value, do: @action_policy_fake_value

  defp resolve_action_policy_command(@action_policy_fake_value, _find_executable) do
    {:ok, :fake}
  end

  defp resolve_action_policy_command(override, _find_executable) when is_binary(override) do
    {:ok, override}
  end

  defp resolve_action_policy_command(nil, find_executable) do
    case find_executable.("beislid") do
      path when is_binary(path) ->
        {:ok, path}

      nil ->
        {:error, {:action_policy_command_missing, @action_policy_override_var}}
    end
  end

  @doc """
  Resolves the configured test team by key, including the workflow states the
  run depends on (`#{@start_state_name}` to create the issue in, and
  `#{@in_progress_state_name}` because `Rondo.RunOnce` transitions to it).
  """
  @spec resolve_team(String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def resolve_team(team_key, graphql \\ &Client.graphql/2) do
    with {:ok, body} <- run_graphql(graphql, @team_query, %{key: team_key}, :resolve_team) do
      case get_in(body, ["data", "teams", "nodes"]) do
        [team | _] -> build_team(team, team_key)
        _ -> {:error, {:team_not_found, team_key}}
      end
    end
  end

  defp build_team(team, team_key) do
    states = get_in(team, ["states", "nodes"]) || []
    start_state = Enum.find(states, &(&1["name"] == @start_state_name))
    in_progress = Enum.find(states, &(&1["name"] == @in_progress_state_name))

    cond do
      is_nil(start_state) ->
        {:error, {:team_state_missing, team_key, @start_state_name, state_names(states)}}

      is_nil(in_progress) ->
        {:error, {:team_state_missing, team_key, @in_progress_state_name, state_names(states)}}

      true ->
        {:ok, %{id: team["id"], key: team["key"], name: team["name"], start_state_id: start_state["id"]}}
    end
  end

  defp state_names(states), do: Enum.map(states, & &1["name"])

  @doc """
  Resolves the configured disposable-issue project by name, scoped to the
  resolved test team (project names are only unique per team, and the issue
  must land in the team whose states were validated). The returned `slug_id`
  is fed to `tracker.project_slug`, matching the poll filter
  (`project.slugId`) by construction.
  """
  @spec resolve_project(String.t(), map(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def resolve_project(project_name, team, graphql \\ &Client.graphql/2) do
    with {:ok, body} <- run_graphql(graphql, @project_query, %{name: project_name}, :resolve_project) do
      case get_in(body, ["data", "projects", "nodes"]) do
        [_ | _] = projects ->
          pick_team_project(projects, project_name, team)

        _ ->
          {:error, {:project_not_found, project_name}}
      end
    end
  end

  defp pick_team_project(projects, project_name, team) do
    case Enum.find(projects, &project_in_team?(&1, team.id)) do
      nil ->
        {:error, {:project_not_in_team, project_name, team.key, Enum.map(projects, & &1["name"])}}

      project ->
        {:ok, %{id: project["id"], name: project["name"], slug_id: project["slugId"]}}
    end
  end

  defp project_in_team?(project, team_id) do
    project
    |> get_in(["teams", "nodes"])
    |> List.wrap()
    |> Enum.any?(&(&1["id"] == team_id))
  end

  @doc """
  Creates the disposable `#{@title_prefix}`-prefixed issue in the test team and
  project, pinned to the `#{@start_state_name}` state.
  """
  @spec create_issue(map(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def create_issue(%{team: team, project: project} = context, graphql \\ &Client.graphql/2) do
    input = %{
      teamId: team.id,
      projectId: project.id,
      stateId: team.start_state_id,
      title: issue_title(),
      description: Map.get(context, :description, default_issue_description())
    }

    with {:ok, body} <- run_graphql(graphql, @issue_create_mutation, %{input: input}, :create_issue) do
      issue = get_in(body, ["data", "issueCreate", "issue"])

      if get_in(body, ["data", "issueCreate", "success"]) == true and is_map(issue) do
        {:ok,
         %{
           id: issue["id"],
           identifier: issue["identifier"],
           url: issue["url"],
           state: get_in(issue, ["state", "name"])
         }}
      else
        {:error, {:issue_create_failed, body}}
      end
    end
  end

  @spec issue_title() :: String.t()
  def issue_title do
    "#{@title_prefix} disposable run #{DateTime.utc_now() |> DateTime.to_iso8601()}"
  end

  @spec marker_file_name() :: String.t()
  def marker_file_name, do: "rondo_e2e_marker.txt"

  @spec marker_content() :: String.t()
  def marker_content, do: "rondo-e2e-ok"

  @spec default_issue_description() :: String.t()
  def default_issue_description do
    """
    Disposable issue created by Rondo's live E2E test. Safe to delete.

    Task: create a file named `#{marker_file_name()}` in the working directory
    containing exactly the line `#{marker_content()}`, then stop.
    """
  end

  @doc "Fetches the issue's current workflow state name for post-run assertions."
  @spec fetch_issue_state(String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_issue_state(issue_id, graphql \\ &Client.graphql/2) do
    with {:ok, body} <- run_graphql(graphql, @issue_state_query, %{id: issue_id}, :fetch_issue_state) do
      case get_in(body, ["data", "issue", "state", "name"]) do
        state when is_binary(state) -> {:ok, state}
        _ -> {:error, {:issue_state_unavailable, issue_id, body}}
      end
    end
  end

  @doc """
  Best-effort cleanup of the disposable issue (Linear `issueDelete`, which
  moves it to the trash). Never raises; failures are logged with context so a
  human can finish cleanup manually.
  """
  @spec cleanup_issue(map() | String.t(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          :ok | {:error, term()}
  def cleanup_issue(issue, graphql \\ &Client.graphql/2)

  def cleanup_issue(%{id: issue_id} = issue, graphql) when is_binary(issue_id) do
    case cleanup_issue(issue_id, graphql) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning(
          "live E2E cleanup failed for issue #{Map.get(issue, :identifier, issue_id)} " <>
            "url=#{Map.get(issue, :url, "unknown")} reason=#{inspect(reason)}; delete it manually in Linear"
        )

        error
    end
  end

  def cleanup_issue(issue_id, graphql) when is_binary(issue_id) do
    case run_graphql(graphql, @issue_delete_mutation, %{id: issue_id}, :cleanup_issue) do
      {:ok, body} ->
        if get_in(body, ["data", "issueDelete", "success"]) == true do
          :ok
        else
          {:error, {:issue_delete_failed, issue_id, body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_graphql(graphql, query, variables, operation) do
    case graphql.(query, variables) do
      {:ok, %{"errors" => errors} = body} when is_list(errors) and errors != [] ->
        {:error, {:linear_graphql_errors, operation, errors, body}}

      {:ok, body} when is_map(body) ->
        {:ok, body}

      {:error, reason} ->
        {:error, {:linear_request_failed, operation, reason}}

      other ->
        {:error, {:unexpected_graphql_result, operation, other}}
    end
  end

  defp parse_max_turns(nil), do: 10

  defp parse_max_turns(value) do
    case Integer.parse(value) do
      {turns, ""} when turns > 0 -> turns
      _ -> 10
    end
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""
end
