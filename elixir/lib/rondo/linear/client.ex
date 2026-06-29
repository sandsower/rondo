defmodule Rondo.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias Rondo.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query RondoLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_with_labels """
  query RondoLinearPollWithLabels($projectSlug: String!, $stateNames: [String!]!, $labelNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}, labels: {name: {in: $labelNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query RondoLinearIssuesById($ids: [ID!]!, $projectSlug: String!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @query_by_ids_with_labels """
  query RondoLinearIssuesByIdWithLabels($ids: [ID!]!, $projectSlug: String!, $labelNames: [String!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}, labels: {name: {in: $labelNames}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @query_context_by_ids """
  query RondoLinearIssueContextById($ids: [ID!]!, $projectSlug: String!, $first: Int!, $relationFirst: Int!, $commentFirst: Int!, $attachmentFirst: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        relations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              title
              state {
                name
              }
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              title
              state {
                name
              }
            }
          }
        }
        comments(first: $commentFirst) {
          nodes {
            id
            body
            updatedAt
            createdAt
            user {
              id
              name
            }
          }
        }
        attachments(first: $attachmentFirst) {
          nodes {
            id
            title
            subtitle
            url
            sourceType
            metadata
            createdAt
            updatedAt
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @query_context_by_ids_with_labels """
  query RondoLinearIssueContextByIdWithLabels($ids: [ID!]!, $projectSlug: String!, $labelNames: [String!]!, $first: Int!, $relationFirst: Int!, $commentFirst: Int!, $attachmentFirst: Int!) {
    issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}, labels: {name: {in: $labelNames}}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        relations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              title
              state {
                name
              }
            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              title
              state {
                name
              }
            }
          }
        }
        comments(first: $commentFirst) {
          nodes {
            id
            body
            updatedAt
            createdAt
            user {
              id
              name
            }
          }
        }
        attachments(first: $attachmentFirst) {
          nodes {
            id
            title
            subtitle
            url
            sourceType
            metadata
            createdAt
            updatedAt
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query RondoLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) do
    project_slug = Config.linear_project_slug()

    cond do
      is_nil(Config.linear_api_token()) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          label_filter = Config.tracker_label_filter()
          do_fetch_by_states(project_slug, Config.linear_active_states(), assignee_filter, label_filter, opts)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      project_slug = Config.linear_project_slug()

      cond do
        is_nil(Config.linear_api_token()) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          # Intentionally passes nil for label_filter: state-based lookups (e.g. terminal
          # cleanup) should see all issues regardless of configured label filter.
          do_fetch_by_states(project_slug, normalized_states, nil, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.uniq()
    |> fetch_visible_issue_states_by_ids()
  end

  @spec fetch_issue_contexts_by_ids([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_contexts_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.uniq()
    |> fetch_visible_issue_contexts_by_ids()
  end

  defp fetch_visible_issue_states_by_ids([]), do: {:ok, []}

  defp fetch_visible_issue_states_by_ids(ids) do
    project_slug = Config.linear_project_slug()

    cond do
      is_nil(Config.linear_api_token()) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        fetch_visible_issue_states_by_ids(ids, project_slug)
    end
  end

  defp fetch_visible_issue_contexts_by_ids([]), do: {:ok, []}

  defp fetch_visible_issue_contexts_by_ids(ids) do
    project_slug = Config.linear_project_slug()

    cond do
      is_nil(Config.linear_api_token()) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        fetch_visible_issue_contexts_by_ids(ids, project_slug)
    end
  end

  defp fetch_visible_issue_states_by_ids(ids, project_slug) do
    with {:ok, assignee_filter} <- routing_assignee_filter() do
      do_fetch_issue_states(ids, assignee_filter, project_slug, Config.tracker_label_filter())
    end
  end

  defp fetch_visible_issue_contexts_by_ids(ids, project_slug) do
    with {:ok, assignee_filter} <- routing_assignee_filter() do
      do_fetch_issue_contexts(ids, assignee_filter, project_slug, Config.tracker_label_filter())
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @spec graphql_raw(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql_raw(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, response} <- request_fun.(payload, headers) do
      case response do
        %{status: 200, body: body} ->
          {:ok, body}

        %{status: status, body: body} ->
          Logger.error(
            "Linear GraphQL request failed status=#{status}" <>
              linear_error_context(payload, response)
          )

          {:error, {:linear_api_status, status, body}}

        other ->
          Logger.error("Linear GraphQL request failed with malformed response=#{inspect(other)}")

          {:error, {:linear_api_request, {:malformed_response, other}}}
      end
    else
      {:ok, response} ->
        Logger.error(
          "Linear GraphQL request failed status=#{response.status}" <>
            linear_error_context(payload, response)
        )

        {:error, {:linear_api_status, response.status, Map.get(response, :body) || Map.get(response, "body")}}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_context_for_test(map(), String.t() | nil) :: map() | nil
  def normalize_issue_context_for_test(issue, assignee \\ nil) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue_context(issue, assignee_filter)
  end

  @doc false
  @spec fetch_issue_contexts_by_ids_for_test(
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_contexts_by_ids_for_test(issue_ids, graphql_fun, opts \\ [])
      when is_list(issue_ids) and is_function(graphql_fun, 2) and is_list(opts) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_contexts(
          ids,
          nil,
          Keyword.get(opts, :project_slug, "test-project"),
          Keyword.get(opts, :label_filter, []),
          graphql_fun
        )
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test(
          [String.t()],
          (String.t(), map() -> {:ok, map()} | {:error, term()}),
          keyword()
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun, opts \\ [])
      when is_list(issue_ids) and is_function(graphql_fun, 2) and is_list(opts) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(
          ids,
          nil,
          Keyword.get(opts, :project_slug, "test-project"),
          Keyword.get(opts, :label_filter, []),
          graphql_fun
        )
    end
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter, label_filter, opts \\ []) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, label_filter, nil, [], opts)
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, label_filter, after_cursor, acc_issues, opts) do
    {query, variables} = build_poll_query(project_slug, state_names, label_filter, after_cursor)

    with {:ok, body} <- graphql(query, variables, opts),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(
            project_slug,
            state_names,
            assignee_filter,
            label_filter,
            next_cursor,
            updated_acc,
            opts
          )

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_poll_query(project_slug, state_names, label_names, after_cursor)
       when is_list(label_names) and label_names != [] do
    {@query_with_labels,
     %{
       projectSlug: project_slug,
       stateNames: state_names,
       labelNames: label_names,
       first: @issue_page_size,
       relationFirst: @issue_page_size,
       after: after_cursor
     }}
  end

  defp build_poll_query(project_slug, state_names, _label_names, after_cursor) do
    {@query,
     %{
       projectSlug: project_slug,
       stateNames: state_names,
       first: @issue_page_size,
       relationFirst: @issue_page_size,
       after: after_cursor
     }}
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter, project_slug, label_filter) do
    do_fetch_issue_states(ids, assignee_filter, project_slug, label_filter, fn query, vars -> graphql(query, vars) end)
  end

  defp do_fetch_issue_states(ids, assignee_filter, project_slug, label_filter, graphql_fun)
       when is_list(ids) and is_binary(project_slug) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, project_slug, label_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _project_slug, _label_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, project_slug, label_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)
    {query, variables} = build_issue_states_by_ids_query(batch_ids, project_slug, label_filter)

    case graphql_fun.(query, variables) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)

          do_fetch_issue_states_page(
            rest_ids,
            assignee_filter,
            project_slug,
            label_filter,
            graphql_fun,
            updated_acc,
            issue_order_index
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_fetch_issue_contexts(ids, assignee_filter, project_slug, label_filter) do
    graphql_fun = fn query, vars -> graphql(query, vars) end

    do_fetch_issue_contexts(ids, assignee_filter, project_slug, label_filter, graphql_fun)
  end

  defp do_fetch_issue_contexts(ids, assignee_filter, project_slug, label_filter, graphql_fun)
       when is_list(ids) and is_binary(project_slug) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_contexts_page(ids, assignee_filter, project_slug, label_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_contexts_page(
         [],
         _assignee_filter,
         _project_slug,
         _label_filter,
         _graphql_fun,
         acc_contexts,
         issue_order_index
       ) do
    acc_contexts
    |> finalize_paginated_issues()
    |> sort_contexts_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_contexts_page(ids, assignee_filter, project_slug, label_filter, graphql_fun, acc_contexts, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)
    {query, variables} = build_issue_contexts_by_ids_query(batch_ids, project_slug, label_filter)

    case graphql_fun.(query, variables) do
      {:ok, body} ->
        with {:ok, contexts} <- decode_linear_context_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(contexts, acc_contexts)

          do_fetch_issue_contexts_page(
            rest_ids,
            assignee_filter,
            project_slug,
            label_filter,
            graphql_fun,
            updated_acc,
            issue_order_index
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_issue_contexts_by_ids_query(batch_ids, project_slug, label_filter)
       when is_list(label_filter) and label_filter != [] do
    {@query_context_by_ids_with_labels,
     %{
       ids: batch_ids,
       projectSlug: project_slug,
       labelNames: label_filter,
       first: length(batch_ids),
       relationFirst: @issue_page_size,
       commentFirst: @issue_page_size,
       attachmentFirst: @issue_page_size
     }}
  end

  defp build_issue_contexts_by_ids_query(batch_ids, project_slug, _label_filter) do
    {@query_context_by_ids,
     %{
       ids: batch_ids,
       projectSlug: project_slug,
       first: length(batch_ids),
       relationFirst: @issue_page_size,
       commentFirst: @issue_page_size,
       attachmentFirst: @issue_page_size
     }}
  end

  defp decode_linear_context_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    contexts =
      nodes
      |> Enum.map(&normalize_issue_context(&1, assignee_filter))
      |> Enum.reject(&is_nil/1)

    {:ok, contexts}
  end

  defp decode_linear_context_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_context_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp sort_contexts_by_requested_ids(contexts, issue_order_index)
       when is_list(contexts) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(contexts, fn
      %{issue: %Issue{id: issue_id}} -> Map.get(issue_order_index, issue_id, fallback_index)
      %{issue: %{"id" => issue_id}} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp normalize_issue_context(issue, assignee_filter) when is_map(issue) do
    case normalize_issue(issue, assignee_filter) do
      nil ->
        nil

      %Issue{} = issue_struct ->
        %{
          issue: issue_struct,
          snapshot: normalize_issue_context_snapshot(issue)
        }
    end
  end

  defp normalize_issue_context_snapshot(issue) when is_map(issue) do
    %{
      "id" => issue["id"],
      "identifier" => issue["identifier"],
      "title" => issue["title"],
      "description" => issue["description"],
      "state" => get_in(issue, ["state", "name"]),
      "updated_at" => parse_datetime(issue["updatedAt"]),
      "labels" => extract_labels(issue),
      "blocked_by" => extract_blockers(issue),
      "relations" => extract_relations(issue),
      "inverse_relations" => extract_inverse_relations(issue),
      "comments" => extract_comments(issue),
      "attachments" => extract_attachments(issue),
      "custom_fields" => extract_custom_fields(issue),
      "created_at" => parse_datetime(issue["createdAt"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp extract_relations(%{"relations" => %{"nodes" => relations}}) when is_list(relations) do
    Enum.map(relations, &normalize_relation_node/1) |> Enum.reject(&is_nil/1)
  end

  defp extract_relations(_), do: []

  defp extract_inverse_relations(%{"inverseRelations" => %{"nodes" => relations}}) when is_list(relations) do
    Enum.map(relations, &normalize_relation_node/1) |> Enum.reject(&is_nil/1)
  end

  defp extract_inverse_relations(_), do: []

  defp normalize_relation_node(%{"type" => relation_type, "issue" => issue}) when is_map(issue) do
    %{
      type: relation_type,
      issue_id: issue["id"],
      issue_identifier: issue["identifier"],
      issue_title: issue["title"],
      issue_state: get_in(issue, ["state", "name"])
    }
  end

  defp normalize_relation_node(_), do: nil

  defp extract_comments(%{"comments" => %{"nodes" => comments}}) when is_list(comments) do
    comments
    |> Enum.map(&normalize_comment_node/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_comments(_), do: []

  defp normalize_comment_node(%{} = comment) do
    %{
      id: comment["id"],
      body: comment["body"],
      updated_at: parse_datetime(comment["updatedAt"]),
      created_at: parse_datetime(comment["createdAt"]),
      author_id: get_in(comment, ["user", "id"]),
      author_name: get_in(comment, ["user", "name"])
    }
  end

  defp normalize_comment_node(_), do: nil

  defp extract_attachments(%{"attachments" => %{"nodes" => attachments}}) when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_attachment_node/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_attachments(_), do: []

  defp normalize_attachment_node(%{} = attachment) do
    %{
      id: attachment["id"],
      title: attachment["title"],
      subtitle: attachment["subtitle"],
      url: attachment["url"],
      source_type: attachment["sourceType"],
      metadata: attachment["metadata"],
      created_at: parse_datetime(attachment["createdAt"]),
      updated_at: parse_datetime(attachment["updatedAt"])
    }
  end

  defp normalize_attachment_node(_), do: nil

  defp extract_custom_fields(%{"customFields" => %{"nodes" => fields}}) when is_list(fields) do
    fields
    |> Enum.map(&normalize_custom_field_node/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp extract_custom_fields(_), do: %{}

  defp normalize_custom_field_node(%{"name" => name} = field) do
    {name, field["value"]}
  end

  defp normalize_custom_field_node(_), do: nil

  defp build_issue_states_by_ids_query(batch_ids, project_slug, label_filter)
       when is_list(label_filter) and label_filter != [] do
    {@query_by_ids_with_labels,
     %{
       ids: batch_ids,
       projectSlug: project_slug,
       labelNames: label_filter,
       first: length(batch_ids),
       relationFirst: @issue_page_size
     }}
  end

  defp build_issue_states_by_ids_query(batch_ids, project_slug, _label_filter) do
    {@query_by_ids,
     %{
       ids: batch_ids,
       projectSlug: project_slug,
       first: length(batch_ids),
       relationFirst: @issue_page_size
     }}
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.linear_api_token() do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.linear_endpoint(),
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.linear_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
