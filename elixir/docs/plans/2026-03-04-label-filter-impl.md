# Label-Based Issue Filtering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Filter Linear issues by label names so Symphony only picks up issues tagged for automation.

**Architecture:** Add `tracker.label_filter` config (list of label names). When set, inject `labels: { name: { in: $labelNames } }` into the GraphQL issues query. When empty/nil, keep current behavior (fetch all matching issues).

**Tech Stack:** Elixir, NimbleOptions, Linear GraphQL API

**Working directory:** `.worktrees/claude-adaptation/elixir/`

---

### Task 1: Add `label_filter` to Config

**Files:**
- Modify: `lib/symphony_elixir/config.ex`

**Step 1: Write the failing test**

Add to `test/symphony_elixir/workspace_and_config_test.exs`:

```elixir
test "config reads tracker label_filter as list of strings" do
  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_label_filter: ["symphony", "autofix"]
  )

  assert Config.tracker_label_filter() == ["symphony", "autofix"]
end

test "config returns empty list when tracker label_filter is nil" do
  write_workflow_file!(Workflow.workflow_file_path(), tracker_label_filter: nil)

  assert Config.tracker_label_filter() == []
end

test "config returns empty list when tracker label_filter is empty list" do
  write_workflow_file!(Workflow.workflow_file_path(), tracker_label_filter: [])

  assert Config.tracker_label_filter() == []
end
```

**Step 2: Run tests to verify they fail**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs --no-color 2>&1 | tail -20`
Expected: FAIL -- `tracker_label_filter` not recognized by test_support / Config has no `tracker_label_filter/0`

**Step 3: Add `tracker_label_filter` to test_support.exs**

In `test/support/test_support.exs`, add the override key and YAML generation:

1. Add `tracker_label_filter: nil` to the defaults keyword list (after `tracker_terminal_states`).
2. Bind it: `tracker_label_filter = Keyword.get(config, :tracker_label_filter)`
3. Add YAML line after `terminal_states`: `"  label_filter: #{yaml_value(tracker_label_filter)}"`

**Step 4: Add schema + getter to config.ex**

In `config.ex`:

1. In `@workflow_options_schema`, inside the `tracker` keys, add:
   ```elixir
   label_filter: [type: {:list, :string}, default: []]
   ```

2. In `extract_tracker_options/1`, add:
   ```elixir
   |> put_if_present(:label_filter, label_filter_value(Map.get(section, "label_filter")))
   ```

3. Add the extractor:
   ```elixir
   defp label_filter_value(values) when is_list(values) do
     filtered =
       values
       |> Enum.filter(&is_binary/1)
       |> Enum.map(&String.trim/1)
       |> Enum.reject(&(&1 == ""))

     if filtered == [], do: :omit, else: filtered
   end

   defp label_filter_value(value) when is_binary(value) do
     csv_value(value)
   end

   defp label_filter_value(_), do: :omit
   ```

4. Add the public getter:
   ```elixir
   @spec tracker_label_filter() :: [String.t()]
   def tracker_label_filter do
     get_in(validated_workflow_options(), [:tracker, :label_filter])
   end
   ```

**Step 5: Run tests to verify they pass**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs --no-color 2>&1 | tail -10`
Expected: all PASS

**Step 6: Commit**

```bash
git add lib/symphony_elixir/config.ex test/support/test_support.exs test/symphony_elixir/workspace_and_config_test.exs
git commit -m "Add tracker.label_filter config option"
```

---

### Task 2: Add label-filtered GraphQL query to Linear client

**Files:**
- Modify: `lib/symphony_elixir/linear/client.ex`

**Step 1: Write the failing test**

Add to `test/symphony_elixir/workspace_and_config_test.exs`:

```elixir
test "linear client sends label filter in GraphQL query when configured" do
  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_label_filter: ["symphony"],
    tracker_api_token: "test-token",
    tracker_project_slug: "test-project"
  )

  test_pid = self()

  request_fun = fn payload, _headers ->
    send(test_pid, {:graphql_payload, payload})

    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "issues" => %{
             "nodes" => [],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }
     }}
  end

  assert {:ok, []} = Client.fetch_candidate_issues(request_fun: request_fun)

  assert_received {:graphql_payload, payload}
  assert payload["variables"]["labelNames"] == ["symphony"]
  assert payload["query"] =~ "labelNames"
end

test "linear client omits label filter from GraphQL query when not configured" do
  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_label_filter: nil,
    tracker_api_token: "test-token",
    tracker_project_slug: "test-project"
  )

  test_pid = self()

  request_fun = fn payload, _headers ->
    send(test_pid, {:graphql_payload, payload})

    {:ok,
     %{
       status: 200,
       body: %{
         "data" => %{
           "issues" => %{
             "nodes" => [],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }
     }}
  end

  assert {:ok, []} = Client.fetch_candidate_issues(request_fun: request_fun)

  assert_received {:graphql_payload, payload}
  refute Map.has_key?(payload["variables"], "labelNames")
  refute payload["query"] =~ "labelNames"
end
```

**Step 2: Run tests to verify they fail**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs --no-color 2>&1 | tail -20`
Expected: FAIL -- `fetch_candidate_issues/1` doesn't accept opts / query doesn't contain labelNames

**Step 3: Add the label-filtered query variant and plumb opts through**

In `lib/symphony_elixir/linear/client.ex`:

1. Add a second query module attribute `@query_with_labels` that's the same as `@query` but with `$labelNames: [String!]!` in the variable signature and `labels: { name: { in: $labelNames } }` added to the filter:

   ```elixir
   @query_with_labels """
   query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $labelNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
     issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}, labels: {name: {in: $labelNames}}}, first: $first, after: $after) {
       nodes {
         <same fields as @query>
       }
       pageInfo {
         hasNextPage
         endCursor
       }
     }
   }
   """
   ```
   (Copy the full node fields from `@query`.)

2. Change `fetch_candidate_issues/0` to `fetch_candidate_issues/1` accepting `opts \\ []`:
   ```elixir
   def fetch_candidate_issues(opts \\ []) do
   ```
   Thread `opts` into `do_fetch_by_states`.

3. In `do_fetch_by_states` and `do_fetch_by_states_page`, accept and thread `opts`. In the page function, choose the query and variables based on label filter:
   ```elixir
   label_filter = Config.tracker_label_filter()
   {query, extra_vars} =
     if label_filter != [] do
       {@query_with_labels, %{labelNames: label_filter}}
     else
       {@query, %{}}
     end
   ```
   Merge `extra_vars` into the graphql call variables. Pass `request_fun` from opts to graphql if present.

4. Update the `graphql/3` function to accept a `:request_fun` option (it already does via `Keyword.get(opts, :request_fun, &post_graphql_request/2)`) -- just make sure `fetch_candidate_issues` threads the opts through to `graphql`.

**Step 4: Run tests to verify they pass**

Run: `mix test test/symphony_elixir/workspace_and_config_test.exs --no-color 2>&1 | tail -10`
Expected: all PASS

**Step 5: Run full test suite**

Run: `mix test --no-color 2>&1 | tail -5`
Expected: 172+ tests, 0 failures (no regressions from the new opts parameter default)

**Step 6: Commit**

```bash
git add lib/symphony_elixir/linear/client.ex test/symphony_elixir/workspace_and_config_test.exs
git commit -m "Add label-based filtering to Linear issue queries"
```

---

### Task 3: Update design doc and clean up

**Files:**
- Modify: `docs/plans/2026-03-04-label-filter-design.md`

**Step 1: Update the design doc to note implementation is complete**

Add a `## Status` section at the bottom: `Implemented in tasks 1-2.`

**Step 2: Run full test suite one final time**

Run: `mix test --no-color 2>&1 | tail -5`
Expected: all tests pass

**Step 3: Commit**

```bash
git add docs/plans/2026-03-04-label-filter-design.md
git commit -m "Mark label filter design doc as implemented"
```
