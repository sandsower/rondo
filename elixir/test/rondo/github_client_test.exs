defmodule Rondo.GitHub.ClientTest do
  use Rondo.TestSupport

  alias Rondo.GitHub.Client, as: GitHubClient
  alias Rondo.Linear.Issue

  @repo "sandsower/memento-vault"
  @json_fields "number,title,body,labels,url,state,createdAt,updatedAt"

  test "normalizes github issue fields and state labels" do
    issue =
      GitHubClient.normalize_issue_for_test(
        %{
          "number" => 21,
          "title" => "Add adapter",
          "body" => "Implement GitHub",
          "state" => "OPEN",
          "url" => "https://github.com/sandsower/memento-vault/issues/21",
          "labels" => [%{"name" => "rondo"}, %{"name" => "status: Todo"}],
          "createdAt" => "2026-05-01T00:00:00Z",
          "updatedAt" => "2026-05-02T00:00:00Z"
        },
        @repo
      )

    assert %Issue{} = issue
    assert issue.id == "#{@repo}#21"
    assert issue.identifier == "GH-21"
    assert issue.title == "Add adapter"
    assert issue.description == "Implement GitHub"
    assert issue.state == "Todo"
    assert issue.labels == ["rondo", "status: Todo"]
    assert issue.url == "https://github.com/sandsower/memento-vault/issues/21"
    assert issue.created_at == ~U[2026-05-01 00:00:00Z]
    assert issue.updated_at == ~U[2026-05-02 00:00:00Z]
  end

  test "normalizes closed github issue without state label as Closed" do
    issue =
      GitHubClient.normalize_issue_for_test(
        %{"number" => 22, "title" => "Closed", "state" => "CLOSED", "labels" => []},
        @repo
      )

    assert issue.state == "Closed"
  end

  test "fetch_candidate_issues requires all labels and skips missing or multiple state labels" do
    runner = fn "gh", args, _opts ->
      send(self(), {:gh, args})

      {Jason.encode!([
         %{"number" => 1, "title" => "Ready", "state" => "OPEN", "labels" => [%{"name" => "rondo"}, %{"name" => "priority: P0"}, %{"name" => "status: Todo"}]},
         %{"number" => 2, "title" => "Missing state", "state" => "OPEN", "labels" => [%{"name" => "rondo"}, %{"name" => "priority: P0"}]},
         %{"number" => 3, "title" => "Invalid state", "state" => "OPEN", "labels" => [%{"name" => "rondo"}, %{"name" => "priority: P0"}, %{"name" => "status: Todo"}, %{"name" => "status: Done"}]},
         %{"number" => 4, "title" => "Terminal", "state" => "OPEN", "labels" => [%{"name" => "rondo"}, %{"name" => "priority: P0"}, %{"name" => "status: Done"}]}
       ]), 0}
    end

    assert {:ok, [issue]} =
             GitHubClient.fetch_candidate_issues(
               repo: @repo,
               runner: runner,
               label_filter: ["rondo", "priority: P0"],
               active_states: ["Todo", "In Progress"],
               state_label_prefix: "status:"
             )

    assert issue.identifier == "GH-1"

    assert_received {:gh, args}

    assert args == [
             "issue",
             "list",
             "--repo",
             @repo,
             "--state",
             "open",
             "--limit",
             "1000",
             "--json",
             @json_fields,
             "--label",
             "rondo",
             "--label",
             "priority: P0"
           ]
  end

  test "fetch_issue_states_by_ids views each configured-repo issue" do
    runner = fn "gh", args, _opts ->
      send(self(), {:gh, args})
      {Jason.encode!(%{"number" => 7, "title" => "Running", "state" => "OPEN", "labels" => [%{"name" => "status: In Progress"}]}), 0}
    end

    assert {:ok, [%Issue{identifier: "GH-7", state: "In Progress"}]} =
             GitHubClient.fetch_issue_states_by_ids(["#{@repo}#7"],
               repo: @repo,
               runner: runner,
               state_label_prefix: "status:"
             )

    assert_received {:gh,
                     [
                       "issue",
                       "view",
                       "7",
                       "--repo",
                       @repo,
                       "--json",
                       @json_fields
                     ]}

    assert {:error, {:github_issue_repo_mismatch, "other/repo#7", @repo}} =
             GitHubClient.fetch_issue_states_by_ids(["other/repo#7"], repo: @repo, runner: runner)
  end

  test "fetch_issues_by_states lists all native states and post-filters workflow labels" do
    runner = fn "gh", args, _opts ->
      send(self(), {:gh, args})

      {Jason.encode!([
         %{"number" => 1, "title" => "Done", "state" => "OPEN", "labels" => [%{"name" => "rondo"}, %{"name" => "status: Done"}]},
         %{"number" => 2, "title" => "Todo", "state" => "OPEN", "labels" => [%{"name" => "rondo"}, %{"name" => "status: Todo"}]}
       ]), 0}
    end

    assert {:ok, [%Issue{identifier: "GH-1", state: "Done"}]} =
             GitHubClient.fetch_issues_by_states(["Done"],
               repo: @repo,
               runner: runner,
               label_filter: ["rondo"],
               state_label_prefix: "status:"
             )

    assert_received {:gh, args}
    assert Enum.slice(args, 0, 8) == ["issue", "list", "--repo", @repo, "--state", "all", "--limit", "1000"]
  end

  test "fetch_issue_states_by_ids omits issues that are no longer visible or readable" do
    runner = fn "gh", args, _opts ->
      send(self(), {:gh, args})

      case args do
        ["issue", "view", "1" | _] ->
          {Jason.encode!(%{"number" => 1, "title" => "Good", "state" => "OPEN", "labels" => [%{"name" => "rondo"}, %{"name" => "status: In Progress"}]}), 0}

        ["issue", "view", "2" | _] ->
          {Jason.encode!(%{"number" => 2, "title" => "Missing owner label", "state" => "OPEN", "labels" => [%{"name" => "status: In Progress"}]}), 0}

        ["issue", "view", "3" | _] ->
          {Jason.encode!(%{"number" => 3, "title" => "Missing state", "state" => "OPEN", "labels" => [%{"name" => "rondo"}]}), 0}

        ["issue", "view", "4" | _] ->
          {Jason.encode!(%{"number" => 4, "title" => "Multiple states", "state" => "OPEN", "labels" => [%{"name" => "rondo"}, %{"name" => "status: Todo"}, %{"name" => "status: Done"}]}), 0}
      end
    end

    assert {:ok, [%Issue{identifier: "GH-1"}]} =
             GitHubClient.fetch_issue_states_by_ids(
               ["#{@repo}#1", "#{@repo}#2", "#{@repo}#3", "#{@repo}#4"],
               repo: @repo,
               runner: runner,
               label_filter: ["rondo"],
               state_label_prefix: "status:"
             )
  end

  test "update_issue_state replaces prefixed state labels and creates missing target label" do
    runner = fn "gh", args, _opts ->
      send(self(), {:gh, args})

      case args do
        ["issue", "view", "5" | _] ->
          {Jason.encode!(%{"number" => 5, "title" => "Work", "state" => "OPEN", "labels" => [%{"name" => "status: Todo"}, %{"name" => "status: Blocked"}, %{"name" => "rondo"}]}), 0}

        ["label", "create", "status: In Progress" | _] ->
          {"already exists", 1}

        _ ->
          {"", 0}
      end
    end

    assert :ok =
             GitHubClient.update_issue_state("#{@repo}#5", "In Progress",
               repo: @repo,
               runner: runner,
               state_label_prefix: "status:"
             )

    assert_received {:gh, ["issue", "view", "5", "--repo", @repo, "--json", @json_fields]}

    assert_received {:gh,
                     [
                       "label",
                       "create",
                       "status: In Progress",
                       "--repo",
                       @repo,
                       "--color",
                       "5319E7",
                       "--description",
                       "Rondo workflow state: In Progress"
                     ]}

    assert_received {:gh, ["issue", "edit", "5", "--repo", @repo, "--add-label", "status: In Progress"]}
    assert_received {:gh, ["issue", "edit", "5", "--repo", @repo, "--remove-label", "status: Todo"]}
    assert_received {:gh, ["issue", "edit", "5", "--repo", @repo, "--remove-label", "status: Blocked"]}
  end

  test "update_issue_state keeps old state labels when adding target state fails" do
    runner = fn "gh", args, _opts ->
      send(self(), {:gh, args})

      case args do
        ["issue", "view", "5" | _] ->
          {Jason.encode!(%{"number" => 5, "title" => "Work", "state" => "OPEN", "labels" => [%{"name" => "status: Todo"}]}), 0}

        ["label", "create", "status: In Progress" | _] ->
          {"", 0}

        ["issue", "edit", "5", "--repo", @repo, "--add-label", "status: In Progress"] ->
          {"add failed", 1}
      end
    end

    assert {:error, {:github_cli_failed, _args, 1, "add failed"}} =
             GitHubClient.update_issue_state("#{@repo}#5", "In Progress",
               repo: @repo,
               runner: runner,
               state_label_prefix: "status:"
             )

    assert_received {:gh, ["issue", "edit", "5", "--repo", @repo, "--add-label", "status: In Progress"]}
    refute_received {:gh, ["issue", "edit", "5", "--repo", @repo, "--remove-label", "status: Todo"]}
  end

  test "create_comment posts through a body file" do
    runner = fn "gh", args, _opts ->
      send(self(), {:gh, args, File.read!(List.last(args))})
      {"", 0}
    end

    assert :ok = GitHubClient.create_comment("#{@repo}#8", "hello from rondo", repo: @repo, runner: runner)

    assert_received {:gh, ["issue", "comment", "8", "--repo", @repo, "--body-file", _path], "hello from rondo"}
  end

  test "maps missing gh auth repo and json errors explicitly" do
    missing_runner = fn "gh", _args, _opts -> raise ErlangError, original: :enoent end
    auth_runner = fn "gh", _args, _opts -> {"run gh auth login", 1} end
    repo_runner = fn "gh", _args, _opts -> {"Could not resolve to a Repository", 1} end
    bad_json_runner = fn "gh", _args, _opts -> {"not json", 0} end

    assert {:error, :missing_github_cli} =
             GitHubClient.fetch_candidate_issues(repo: @repo, runner: missing_runner)

    assert {:error, {:github_auth_failed, _}} =
             GitHubClient.fetch_candidate_issues(repo: @repo, runner: auth_runner)

    assert {:error, {:github_repo_unavailable, @repo, _}} =
             GitHubClient.fetch_candidate_issues(repo: @repo, runner: repo_runner)

    assert {:error, {:github_decode_failed, _}} =
             GitHubClient.fetch_candidate_issues(repo: @repo, runner: bad_json_runner)
  end
end
