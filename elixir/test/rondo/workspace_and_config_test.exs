defmodule Rondo.WorkspaceAndConfigTest do
  use Rondo.TestSupport
  alias Rondo.Gates
  alias Rondo.Linear.Client
  alias Rondo.RemoteShell
  alias Rondo.RunLedger
  alias Rondo.WorkerPool

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      action_policy_command: fake_action_policy("allow")
    )

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      refute File.exists?(Path.join([second_workspace, "tmp", "scratch.txt"]))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      expected_workspace = Path.join(expected_canonical_path(workspace_root), "MT-STALE")
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow")
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == expected_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {escape_reason, _, _}} = Workspace.create_for_issue("MT-SYM")
      assert escape_reason in [:workspace_symlink_escape, :workspace_outside_root]
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      expected_root = expected_canonical_path(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_equals_root, ^expected_root, ^expected_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace hooks stop before execution when action policy asks for guidance" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-hook-policy-ask-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("ask_hooks"),
        hook_after_create: "touch should-not-run"
      )

      assert {:error, {:action_policy_guidance_required, interrupt}} = Workspace.create_for_issue("MT-POLICY-ASK")
      assert interrupt["reason"] == "action_policy_guidance_required"
      assert interrupt["blocked_side_effect"]["action"] == "workspace.hook.after_create"
      assert interrupt["blocked_side_effect"]["resume_safe"] == false
      refute Enum.any?(interrupt["suggested_responses"], &(&1["id"] == "approve_once"))
      refute File.exists?(Path.join([workspace_root, "MT-POLICY-ASK", "should-not-run"]))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow")
      )

      workspace = Path.join(expected_canonical_path(workspace_root), "MT-608")

      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow")
      )

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup stops before deletion when action policy denies" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-issue-workspace-cleanup-deny-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      File.mkdir_p!(target_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("deny")
      )

      assert {:error, {:action_policy_denied, %{"decision" => "deny"}}} = Workspace.remove(target_workspace)
      assert File.exists?(Path.join(target_workspace, "marker.txt"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "before_remove hook policy asks stop deletion with guidance" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-before-remove-policy-ask-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      File.mkdir_p!(target_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("ask_hooks"),
        hook_before_remove: "touch should-not-run"
      )

      assert {:error, {:action_policy_guidance_required, interrupt}} = Workspace.remove(target_workspace)
      assert interrupt["blocked_side_effect"]["action"] == "workspace.hook.before_remove"
      assert File.exists?(Path.join(target_workspace, "marker.txt"))
      refute File.exists?(Path.join(target_workspace, "should-not-run"))
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["Backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: %{
                          "errors" => [
                            %{
                              "message" => "Variable \"$ids\" got invalid value",
                              "extensions" => %{"code" => "BAD_USER_INPUT"}
                            }
                          ]
                        }
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear client graphql_raw preserves successful GraphQL bodies including errors" do
    assert {:ok, body} =
             Client.graphql_raw(
               "query Viewer { viewer { id } }",
               %{},
               request_fun: fn _payload, _headers ->
                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "errors" => [
                        %{
                          "message" => "Variable \"$ids\" got invalid value",
                          "extensions" => %{"code" => "BAD_USER_INPUT"}
                        }
                      ],
                      "data" => nil
                    }
                  }}
               end
             )

    assert Enum.at(body["errors"], 0)["message"] == "Variable \"$ids\" got invalid value"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      claude_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      assert Config.workspace_hooks().after_create =~ "echo after_create > after_create.log"
      assert Config.workspace_hooks().before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:rondo, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:rondo, :workspace_hook_timeout_ms)
      else
        Application.put_env(:rondo, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:rondo, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: nil,
      max_concurrent_agents: nil,
      claude_turn_timeout_ms: nil,
      claude_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert Config.linear_endpoint() == "https://api.linear.app/graphql"
    assert Config.linear_api_token() == nil
    assert Config.linear_project_slug() == nil
    assert Config.workspace_root() == Path.join(System.tmp_dir!(), "rondo_workspaces")
    assert Config.max_concurrent_agents() == 10
    assert Config.claude_command() == "claude"
    assert Config.claude_permission_mode() == "bypassPermissions"
    assert Config.claude_dangerously_skip_permissions?() == true
    assert Config.claude_max_turns() == 50
    assert Config.claude_output_format() == "stream-json"
    assert Config.claude_model() == nil
    assert Config.claude_allowed_tools() == nil
    assert Config.claude_turn_timeout_ms() == 3_600_000
    assert Config.claude_stall_timeout_ms() == 300_000
    assert %{command: action_policy_command, run_mode: "unattended-auto"} = Config.action_policy()
    assert File.exists?(action_policy_command)
    assert Config.action_policy_command() == action_policy_command
    assert Config.action_policy_run_mode() == "unattended-auto"
    assert Config.process_provider() == %{kind: "native", required: false, artifact_path: nil}
    assert Config.process_provider_kind() == "native"
    assert Config.process_provider_required?() == false
    assert Config.model_routing() == %{tiers: %{}, floor: %{}, defaults: %{}, step_hints: %{}, profiles: %{}}

    write_workflow_file!(Workflow.workflow_file_path(),
      model_routing: %{
        "tiers" => %{"light" => [%{"adapter" => "pi", "model" => "openai/gpt-4o-mini"}]},
        "floor" => %{"tier" => "standard", "mode" => "require"}
      }
    )

    assert Config.model_routing() == %{
             tiers: %{light: [%{adapter: "pi", model: "openai/gpt-4o-mini"}]},
             floor: %{tier: "standard", mode: "require"},
             defaults: %{},
             step_hints: %{},
             profiles: %{}
           }

    write_workflow_file!(Workflow.workflow_file_path(), process_provider_required: true)
    assert Config.process_provider() == %{kind: "native", required: true, artifact_path: nil}
    assert Config.process_provider_required?() == true

    write_workflow_file!(Workflow.workflow_file_path(), process_provider_required: "maybe")
    assert {:error, {:invalid_workflow_config, _, [%{path: "process_provider.required"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), process_provider_kind: "beislid", process_provider_artifact_path: "/tmp/beislid-process.json")
    assert Config.process_provider() == %{kind: "beislid", required: false, artifact_path: "/tmp/beislid-process.json"}
    assert Config.process_provider_kind() == "beislid"
    assert Config.process_provider_artifact_path() == "/tmp/beislid-process.json"
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), process_provider_kind: "mystery")
    assert {:error, {:invalid_workflow_config, _, [%{path: "process_provider.kind"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), action_policy_command: "/tmp/beislid", action_policy_run_mode: "supervised-auto")
    assert Config.action_policy() == %{command: "/tmp/beislid", run_mode: "supervised-auto", policy_file: nil}
    assert Config.action_policy_policy_file() == nil

    write_workflow_file!(Workflow.workflow_file_path(), action_policy_run_mode: "YOLO")
    assert {:error, {:invalid_workflow_config, _, [%{path: "action_policy.run_mode"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), action_policy_command: "")
    assert {:error, {:invalid_workflow_config, _, [%{path: "action_policy.command"}]}} = Config.validate!()

    policy_file_dir = Path.join(System.tmp_dir!(), "rondo-policy-file-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(policy_file_dir)
    on_exit(fn -> File.rm_rf!(policy_file_dir) end)
    policy_file = Path.join(policy_file_dir, "policy.json")
    File.write!(policy_file, ~s({"modes": {}}))

    write_workflow_file!(Workflow.workflow_file_path(), action_policy_policy_file: policy_file)
    assert :ok = Config.validate!()
    assert Config.action_policy_policy_file() == policy_file
    assert %{policy_file: ^policy_file} = Config.action_policy()

    write_workflow_file!(Workflow.workflow_file_path(), action_policy_policy_file: "  #{policy_file}  ")
    assert :ok = Config.validate!()
    assert Config.action_policy_policy_file() == policy_file

    missing_policy_file = Path.join(policy_file_dir, "does-not-exist.json")
    write_workflow_file!(Workflow.workflow_file_path(), action_policy_policy_file: missing_policy_file)
    assert {:error, {:invalid_workflow_config, _, [%{path: "action_policy.policy_file"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), action_policy_policy_file: policy_file_dir)
    assert {:error, {:invalid_workflow_config, _, [%{path: "action_policy.policy_file"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), claude_permission_mode: "acceptEdits")
    assert Config.claude_permission_mode() == "acceptEdits"

    write_workflow_file!(Workflow.workflow_file_path(), claude_permission_mode: "YOLO")
    assert {:error, {:invalid_workflow_config, _, [%{path: "claude.permission_mode"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), claude_turn_timeout_ms: 0)
    assert {:error, {:invalid_workflow_config, _, [%{path: "claude.turn_timeout_ms"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), claude_stall_timeout_ms: -1)
    assert {:error, {:invalid_workflow_config, _, [%{path: "claude.stall_timeout_ms"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "claude --model opus")
    assert Config.claude_command() == "claude --model opus"

    for invalid_active_states <- ["", ",", [], [""]] do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: invalid_active_states)
      assert {:error, {:invalid_workflow_config, _, [%{path: "tracker.active_states"}]}} = Config.validate!()
    end

    for invalid_review_states <- ["", ",", [], [""]] do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_review_states: invalid_review_states)
      assert {:error, {:invalid_workflow_config, _, [%{path: "tracker.review_states"}]}} = Config.validate!()
    end

    write_workflow_file!(Workflow.workflow_file_path(), tracker_terminal_states: ",")
    assert {:error, {:invalid_workflow_config, _, [%{path: "tracker.terminal_states"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, _, [%{path: "agent.max_concurrent_agents"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad", "" => 1},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _, errors}} = Config.validate!()
    error_paths = Enum.map(errors, & &1.path)
    assert "tracker.active_states" in error_paths
    assert "tracker.terminal_states" in error_paths
    assert "polling.interval_ms" in error_paths
    assert "workspace.root" in error_paths
    assert "agent.max_retry_backoff_ms" in error_paths
    assert "agent.max_concurrent_agents_by_state.review" in error_paths
    assert "agent.max_concurrent_agents_by_state.done" in error_paths
    assert Enum.any?(errors, &(&1.path == "agent.max_concurrent_agents_by_state" and &1.message == "state name must be non-empty"))
    assert "hooks.timeout_ms" in error_paths
    assert "observability.dashboard_enabled" in error_paths
    assert "observability.refresh_ms" in error_paths
    assert "observability.render_interval_ms" in error_paths
    assert "server.port" in error_paths
    assert "server.host" in error_paths

    write_workflow_file!(Workflow.workflow_file_path(), claude_command: "claude")
    assert Config.claude_command() == "claude"
  end

  test "config wires the owned-branch handoff policy file" do
    expected_policy_file = Path.expand("../../..", __DIR__) |> Path.join(".beislid/action-policy.json")

    write_workflow_file!(Workflow.workflow_file_path(),
      action_policy_policy_file: expected_policy_file
    )

    assert :ok = Config.validate!()
    assert Config.action_policy_policy_file() == expected_policy_file
    assert %{policy_file: ^expected_policy_file} = Config.action_policy()

    sandbox_status = %{baseline: "none", default_branch: false, uncommitted_changes: false}

    assert {:ok, %{"decision" => "allow"}} =
             Rondo.ActionPolicy.evaluate("git.push", ["git-remote"],
               policy_file: expected_policy_file,
               sandbox_status: sandbox_status
             )

    assert {:ok, %{"decision" => "allow"}} =
             Rondo.ActionPolicy.evaluate("gh.pr.create", ["git-remote"],
               policy_file: expected_policy_file,
               sandbox_status: sandbox_status
             )
  end

  test "config preserves model routing step hints" do
    write_workflow_file!(Workflow.workflow_file_path(),
      model_routing: %{
        "defaults" => %{"tier" => "standard", "mode" => "prefer"},
        "step_hints" => %{
          "initial" => %{"skill" => "kickoff", "phase" => "context_discovery", "tier" => "frontier"}
        }
      }
    )

    assert :ok = Config.validate!()

    assert Config.model_routing() == %{
             tiers: %{},
             floor: %{},
             defaults: %{tier: "standard", mode: "prefer"},
             step_hints: %{
               initial: %{
                 "skill" => "kickoff",
                 "phase" => "context_discovery",
                 "tier" => "frontier"
               }
             },
             profiles: %{}
           }
  end

  test "config prefers initial_spawn over initial when both aliases are present" do
    write_workflow_file!(Workflow.workflow_file_path(),
      model_routing: %{
        "step_hints" => %{
          "initial" => %{"skill" => "kickoff", "tier" => "standard"},
          "initial_spawn" => %{"skill" => "kickoff", "tier" => "frontier"}
        }
      }
    )

    assert :ok = Config.validate!()

    assert Config.model_routing() == %{
             tiers: %{},
             floor: %{},
             defaults: %{},
             step_hints: %{
               initial: %{"skill" => "kickoff", "tier" => "frontier"}
             },
             profiles: %{}
           }
  end

  test "config ignores malformed model routing step hints" do
    write_workflow_file!(Workflow.workflow_file_path(),
      model_routing: %{"step_hints" => "bad"}
    )

    assert Config.model_routing() == %{tiers: %{}, floor: %{}, defaults: %{}, step_hints: %{}, profiles: %{}}
  end

  test "config preserves model routing profiles" do
    write_workflow_file!(Workflow.workflow_file_path(),
      model_routing: %{
        "profiles" => %{
          "bulk_implementation" => %{"tier" => "light", "mode" => "prefer", "adapter" => "pi"}
        }
      }
    )

    assert Config.model_routing() == %{
             tiers: %{},
             floor: %{},
             defaults: %{},
             step_hints: %{},
             profiles: %{"bulk_implementation" => %{tier: :light, mode: "prefer", adapter: "pi"}}
           }
  end

  test "config reads flat gate definitions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      gates: [
        %{name: "unit", command: "mix test", timeout_ms: 120_000},
        %{name: "format", command: "mix format --check-formatted"}
      ]
    )

    assert Config.gates() == [
             %{name: "unit", command: "mix test", timeout_ms: 120_000, action_id: nil, action_classes: ["read"]},
             %{name: "format", command: "mix format --check-formatted", timeout_ms: 60_000, action_id: nil, action_classes: ["read"]}
           ]

    write_workflow_file!(Workflow.workflow_file_path(),
      gates: [
        %{
          name: "mutating",
          command: "mix deps.get",
          action_id: "dependency.install",
          action_classes: ["workspace-write", "dependency-install"]
        }
      ]
    )

    assert [
             %{
               action_id: "dependency.install",
               action_classes: ["workspace-write", "dependency-install"]
             }
           ] = Config.gates()
  end

  test "config validates flat gate definitions" do
    write_workflow_file!(Workflow.workflow_file_path(), gates: "mix test")
    assert {:error, {:invalid_workflow_config, _, [%{path: "gates"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), gates: [%{name: "", command: "mix test"}])
    assert {:error, {:invalid_workflow_config, _, [%{path: "gates.0.name"}]}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), gates: [%{name: "unit", command: "", timeout_ms: 0}])
    assert {:error, {:invalid_workflow_config, _, errors}} = Config.validate!()
    error_paths = Enum.map(errors, & &1.path)
    assert "gates.0.command" in error_paths
    assert "gates.0.timeout_ms" in error_paths

    for invalid_classes <- [[], [""], [123], ["workspace-write", ""]] do
      write_workflow_file!(Workflow.workflow_file_path(),
        gates: [%{name: "unit", command: "mix test", action_classes: invalid_classes}]
      )

      assert {:error, {:invalid_workflow_config, _, [%{path: "gates.0.action_classes"}]}} = Config.validate!()
    end

    write_workflow_file!(Workflow.workflow_file_path(), gates: [%{name: "unit", command: "mix test", action_id: ""}])
    assert {:error, {:invalid_workflow_config, _, [%{path: "gates.0.action_id"}]}} = Config.validate!()
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "rondo-workspace-root")
    api_key = "resolved-secret"
    claude_bin = Path.join(["~", "bin", "claude"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      claude_command: "#{claude_bin} -p"
    )

    assert Config.linear_api_token() == api_key
    assert Config.workspace_root() == Path.expand(workspace_root)
    assert Config.claude_command() == "#{claude_bin} -p"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "rondo-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    assert Config.linear_api_token() == "env:#{api_key_env_var}"
    assert Config.workspace_root() == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    tracker:
      kind: memory
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.max_concurrent_agents() == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10
  end

  test "config reads tracker label_filter as list of strings" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_label_filter: ["rondo", "autofix"]
    )

    assert Config.tracker_label_filter() == ["rondo", "autofix"]
  end

  test "config supports github tracker settings" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_project_slug: nil,
      tracker_repo: "sandsower/memento-vault",
      tracker_state_label_prefix: "status:",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed"]
    )

    assert Config.tracker_kind() == "github"
    assert Config.tracker_repo() == "sandsower/memento-vault"
    assert Config.tracker_state_label_prefix() == "status:"
    assert Config.tracker_active_states() == ["Todo", "In Progress"]
    assert Config.tracker_terminal_states() == ["Done", "Closed"]
    assert Config.validate!() == :ok
    assert Tracker.adapter() == Rondo.GitHub.Adapter
  end

  test "config requires owner/repo for github tracker" do
    for invalid_repo <- [nil, "owner", "/repo", "owner/", "owner/repo/extra", "owner repo/name"] do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_project_slug: nil,
        tracker_repo: invalid_repo
      )

      assert {:error, {:invalid_workflow_config, _, [%{path: "tracker.repo"}]}} = Config.validate!()
    end
  end

  test "linear tracker still routes to linear adapter" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    assert Tracker.adapter() == Rondo.Linear.Adapter
  end

  test "config returns empty list when tracker label_filter is nil" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_label_filter: nil)

    assert Config.tracker_label_filter() == []
  end

  test "config returns empty list when tracker label_filter is empty list" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_label_filter: [])

    assert Config.tracker_label_filter() == []
  end

  test "linear client sends label filter in GraphQL query when configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_label_filter: ["rondo"],
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
    assert payload["variables"][:labelNames] == ["rondo"]
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
    refute Map.has_key?(payload["variables"], :labelNames)
    refute payload["query"] =~ "labelNames"
  end

  test "linear client filters candidate polling to configured assignee" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: "dev@example.com",
      tracker_api_token: "test-token",
      tracker_project_slug: "test-project"
    )

    request_fun = fn _payload, _headers ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => %{
             "issues" => %{
               "nodes" => [
                 %{
                   "id" => "issue-1",
                   "identifier" => "MT-1",
                   "title" => "Mine",
                   "state" => %{"name" => "Todo"},
                   "assignee" => %{"id" => "dev@example.com"}
                 },
                 %{
                   "id" => "issue-2",
                   "identifier" => "MT-2",
                   "title" => "Other",
                   "state" => %{"name" => "Todo"},
                   "assignee" => %{"id" => "someone-else@example.com"}
                 }
               ],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }
       }}
    end

    assert Config.linear_assignee() == "dev@example.com"
    assert {:ok, issues} = Client.fetch_candidate_issues(request_fun: request_fun)

    assert Enum.map(issues, &{&1.identifier, &1.assigned_to_worker}) == [
             {"MT-1", true},
             {"MT-2", false}
           ]
  end

  test "config validates release_loop closeout merge.mode in the nested merge section" do
    write_workflow_file!(Workflow.workflow_file_path(), release_loop_merge_mode: "sometimes")

    assert {:error, {:invalid_workflow_config, _, [%{path: "release_loop.closeout.merge.mode"}]}} =
             Config.validate!()
  end

  test "config warns on unknown workflow keys instead of dropping them silently" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: "project",
      model_routing: %{
        "profiles" => %{
          "bulk_implementation" => %{
            "tier" => "light",
            "mode" => "prefer",
            "adapter" => "pi"
          }
        }
      },
      claude_command: "/usr/bin/claude"
    )

    content =
      Workflow.workflow_file_path()
      |> File.read!()
      |> String.replace(
        ~S(  project_slug: "project"),
        ~S(  project_slug: "project"
  typo_key: "surprise")
      )
      |> String.replace(
        ~S(      adapter: "pi"),
        ~S(      adapter: "pi"
      typo: "oops")
      )

    File.write!(Workflow.workflow_file_path(), content)

    log =
      capture_log(fn ->
        assert :ok = Config.validate!()
      end)

    assert log =~ "unknown config key section=tracker key=typo_key"
    assert log =~ "unknown config key section=model_routing.profiles.bulk_implementation key=typo"
  end

  test "workflow load failure logs explicit fallback before defaults are used" do
    original_path = Workflow.workflow_file_path()
    missing_path = Path.join(Path.dirname(original_path), "MISSING_WORKFLOW.md")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_path)

      case Supervisor.restart_child(Rondo.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end)

    Workflow.set_workflow_file_path(missing_path)

    if Process.whereis(WorkflowStore) do
      case Supervisor.terminate_child(Rondo.Supervisor, WorkflowStore) do
        :ok -> :ok
        {:ok, _pid} -> :ok
        {:error, :not_found} -> :ok
        {:error, {:already_terminated, _pid}} -> :ok
      end
    end

    log =
      capture_log(fn ->
        assert String.contains?(Config.workflow_prompt(), "You are working on a Linear issue.")
        assert Config.poll_interval_ms() == 30_000
      end)

    assert log =~ "WORKFLOW.md load failed"
    assert log =~ "defaults are being used"
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as claude instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "hook commands interpolate {{ workspace.path }} and {{ issue.identifier }}" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-hook-interpolation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_after_create: ~s(echo "ws={{ workspace.path }} id={{ issue.identifier }}" > marker.txt)
      )

      assert {:ok, workspace} = Workspace.create_for_issue("DC-1234")

      marker = File.read!(Path.join(workspace, "marker.txt"))
      assert marker =~ "ws=#{workspace}" or marker =~ "ws='#{workspace}'"
      assert marker =~ "id=DC-1234" or marker =~ "id='DC-1234'"
    after
      File.rm_rf(test_root)
    end
  end

  test "before_run hook interpolates {{ workspace.path }} and {{ issue.identifier }}" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-before-run-interpolation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_before_run: ~s(echo "ws={{ workspace.path }} id={{ issue.identifier }}" > before_run.txt)
      )

      issue = %Issue{id: "issue-abc", identifier: "DC-5678"}
      assert {:ok, workspace} = Workspace.create_for_issue(issue)
      assert :ok = Workspace.run_before_run_hook(workspace, issue)

      marker = File.read!(Path.join(workspace, "before_run.txt"))
      assert marker =~ "ws=#{workspace}" or marker =~ "ws='#{workspace}'"
      assert marker =~ "id=DC-5678" or marker =~ "id='DC-5678'"
    after
      File.rm_rf(test_root)
    end
  end

  test "worker pool selects ssh hosts by load and preserves the preferred host when it has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_max_concurrent_agents_per_host: 3,
      worker_ssh_hosts: [
        %{name: "east", host: "east.example", user: "claude", port: 2222, max_concurrent_agents: 2},
        %{name: "west", host: "west.example", max_concurrent_agents: 1}
      ]
    )

    [east, west] = WorkerPool.hosts()

    assert east == %{
             id: "east",
             host: "east.example",
             user: "claude",
             port: 2222,
             max_concurrent_agents: 2
           }

    assert west == %{
             id: "west",
             host: "west.example",
             user: nil,
             port: nil,
             max_concurrent_agents: 1
           }

    assert WorkerPool.host_id(%{name: "named"}) == "named"
    assert WorkerPool.host_id(%{host: "hosted"}) == "hosted"
    assert WorkerPool.host_id("literal") == "literal"
    assert is_nil(WorkerPool.host_id(nil))
    assert WorkerPool.host_loads([%{}, %{worker_host: nil}]) == %{}

    assert {:ok, selected} = WorkerPool.select_host([%{worker_host: east}])
    assert selected == west

    assert {:ok, preferred_from_map} = WorkerPool.select_host([%{worker_host: east}], preferred_host: %{host: "west.example"})
    assert preferred_from_map == west

    assert {:ok, preferred} = WorkerPool.select_host([%{worker_host: east}], preferred_host: "east")
    assert preferred == east

    saturated = [
      %{worker_host: east},
      %{worker_host: east},
      %{worker_host: west},
      %{worker_host: west}
    ]

    assert {:wait, :all_hosts_at_capacity} = WorkerPool.select_host(saturated)
  end

  test "worker pool waits when no ssh hosts are configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: [],
      worker_max_concurrent_agents_per_host: 3
    )

    assert {:wait, :no_workers_configured} = WorkerPool.select_host([])
  end

  test "run ledger snapshots worker host details in the manifest" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-run-ledger-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      issue = %Issue{id: "issue-1", identifier: "LDG-1", title: "Ledger snapshot"}

      assert {:ok, map_ledger} =
               RunLedger.create_run(issue,
                 workspace_root: workspace_root,
                 worker_host: %{id: "alpha", host: "alpha.example", user: nil, port: nil}
               )

      assert get_in(map_ledger.manifest, ["repo", "worker_host"]) == %{
               id: "alpha",
               host: "alpha.example"
             }

      assert {:ok, string_ledger} =
               RunLedger.create_run(issue,
                 workspace_root: workspace_root,
                 worker_host: "beta.example"
               )

      assert get_in(string_ledger.manifest, ["repo", "worker_host"]) == %{
               id: "beta.example",
               host: "beta.example"
             }

      assert {:ok, nil_ledger} = RunLedger.create_run(issue, workspace_root: workspace_root)
      refute get_in(nil_ledger.manifest, ["repo", "worker_host"])

      assert {:ok, fallback_ledger} =
               RunLedger.create_run(issue,
                 workspace_root: workspace_root,
                 worker_host: 123,
                 git_runner: fn _args, _workspace -> {"", 0} end
               )

      refute get_in(fallback_ledger.manifest, ["repo", "worker_host"])
    after
      File.rm_rf(test_root)
    end
  end

  test "remote workspace lifecycle routes create, hooks, and removal through ssh" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    old_home = System.get_env("HOME")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      ssh_trace = Path.join(test_root, "ssh.trace")
      hook_trace = Path.join(test_root, "hooks.trace")
      fake_ssh_dir = fake_ssh(ssh_trace)
      home_dir = Path.join(test_root, "home")
      remote_host = %{id: "remote-1", host: "remote.example", user: "claude", port: 2222}

      File.mkdir_p!(test_root)
      File.mkdir_p!(home_dir)
      File.write!(Path.join(home_dir, ".profile"), "PATH=\"#{fake_ssh_dir}:$PATH\"\nexport PATH\n")
      File.write!(ssh_trace, "")
      File.write!(hook_trace, "")
      System.put_env("HOME", home_dir)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow"),
        hook_after_create: "printf 'after_create:%s\\n' \"$(pwd)\" >> #{hook_trace}",
        hook_before_remove: "printf 'before_remove:%s\\n' \"$(pwd)\" >> #{hook_trace}"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-REMOTE", worker_host: remote_host)
      assert workspace == Path.join(expected_canonical_path(workspace_root), "MT-REMOTE")
      assert File.dir?(workspace)
      assert File.read!(hook_trace) =~ "after_create:#{workspace}"

      assert {:ok, []} = Workspace.remove(workspace, worker_host: remote_host)
      refute File.exists?(workspace)
      assert File.read!(hook_trace) =~ "before_remove:#{workspace}"

      ssh_trace_contents = File.read!(ssh_trace)
      assert ssh_trace_contents =~ "mkdir -p"
      assert ssh_trace_contents =~ "rm -rf"
    after
      restore_env("HOME", old_home)
      File.rm_rf(test_root)
    end
  end

  test "remote shell helpers and remote gates exercise ssh fallbacks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "rondo-elixir-remote-shell-#{System.unique_integer([:positive])}"
      )

    old_home = System.get_env("HOME")
    old_path = System.get_env("PATH")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "repo")
      run_dir = Path.join(test_root, "run")
      ssh_trace = Path.join(test_root, "ssh.trace")
      fake_ssh_dir = fake_ssh(ssh_trace)
      home_dir = Path.join(test_root, "home")
      remote_host = %{host: "remote.example"}
      remote_user_host = %{user: "claude", host: "remote.example", port: 2222}
      empty_path_dir = Path.join(test_root, "empty-path")

      File.mkdir_p!(workspace)
      File.mkdir_p!(home_dir)
      File.mkdir_p!(empty_path_dir)
      File.write!(Path.join(home_dir, ".profile"), "PATH=\"#{fake_ssh_dir}:$PATH\"\nexport PATH\n")
      File.write!(ssh_trace, "")
      System.put_env("HOME", home_dir)

      {_output, 0} = System.cmd("git", ["init", "-q"], cd: workspace)

      assert RemoteShell.worker_host(%{worker_host: remote_host}) == remote_host
      assert RemoteShell.enabled?(%{worker_host: remote_host})
      assert RemoteShell.command_line("echo hi", %{worker_host: remote_host}) =~ "ssh"
      assert RemoteShell.command_line("echo hi", %{worker_host: remote_host}) =~ "remote.example"
      refute RemoteShell.command_line("echo hi", %{worker_host: remote_host}) =~ "@"
      assert RemoteShell.command_line("echo hi", worker_host: remote_user_host) =~ "claude@remote.example"
      assert RemoteShell.command_line_in_workspace("pwd", workspace, []) =~ "cd '"
      assert RemoteShell.command_line_in_workspace("pwd", workspace, %{worker_host: remote_host}) =~ "ssh"
      assert RemoteShell.shell_command("git", ["status", "--porcelain"]) == "git 'status' '--porcelain'"
      assert RemoteShell.shell_escape("it's ok") == "'it'\"'\"'s ok'"
      assert {shell_path, shell_args} = RemoteShell.spawn_invocation("echo", ["hello"], workspace, [])
      assert is_binary(shell_path)
      assert shell_args |> Enum.join(" ") =~ "echo"

      assert {remote_shell_path, _remote_shell_args} =
               RemoteShell.spawn_invocation("echo", ["hello"], workspace, %{worker_host: remote_host})

      assert is_binary(remote_shell_path)
      assert {"", 0} = RemoteShell.run_in_workspace("git status --porcelain", workspace, [])
      assert {"", 0} = RemoteShell.run_in_workspace("git status --porcelain", workspace, %{worker_host: remote_host})
      assert {"ok", 0} = RemoteShell.run("printf ok", %{worker_host: remote_host})
      assert {"", 0} = RemoteShell.git_runner(worker_host: remote_host).(["status", "--porcelain"], workspace)

      System.put_env("PATH", empty_path_dir)
      assert {fallback_shell, _fallback_args} = RemoteShell.spawn_invocation("echo", ["hello"], workspace, [])
      assert fallback_shell == "/bin/sh"
      restore_env("PATH", old_path)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        action_policy_command: fake_action_policy("allow")
      )

      File.mkdir_p!(run_dir)

      assert {:error, summary} =
               Gates.run(
                 [
                   %{name: "remote-ok", command: "printf ok", timeout_ms: 1_000},
                   %{name: "remote-timeout", command: "sleep 1", timeout_ms: 10}
                 ],
                 workspace,
                 run_dir: run_dir,
                 worker_host: remote_host,
                 action_policy: true
               )

      assert summary.status in [:pass, :fail, :timeout]
      assert [%{status: :pass} = _ok, %{status: :timeout} = timeout] = summary.results
      assert timeout.exit_status in [124, nil]
      assert File.read!(ssh_trace) =~ "printf ok"
    after
      restore_env("HOME", old_home)
      restore_env("PATH", old_path)
      File.rm_rf(test_root)
    end
  end

  defp fake_ssh(trace_file) do
    dir = Path.join(System.tmp_dir!(), "rondo-fake-ssh-dir-#{System.unique_integer([:positive, :monotonic])}")
    path = Path.join(dir, "ssh")
    File.mkdir_p!(dir)

    File.write!(path, """
    #!/bin/sh
    printf '%s\n' "$*" >> "#{trace_file}"
    while [ $# -gt 0 ]; do
      case "$1" in
        -o|-p) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    shift
    exec "$@"
    """)

    File.chmod!(path, 0o755)
    dir
  end

  defp fake_action_policy(decision) do
    dir = Path.join(System.tmp_dir!(), "rondo-fake-action-policy-dir-#{System.unique_integer([:positive, :monotonic])}")
    path = Path.join(dir, "beislid-fake")
    File.mkdir_p!(dir)

    File.write!(path, """
    #!/bin/sh
    action=""
    mode=""
    classes=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --action) action="$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        --class) classes="$classes${classes:+,}$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    decision="#{decision}"
    case "$decision:$action" in
      ask_hooks:workspace.hook.*) decision="ask" ;;
      ask_hooks:*) decision="allow" ;;
    esac
    printf '{"decision":"%s","action":"%s","mode":"%s","classes":["%s"],"log_level":"warning","requires_human":true,"reason":"test %s","matched_rules":[]}' "$decision" "$action" "$mode" "$classes" "$decision"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp expected_canonical_path(path) do
    path
    |> Path.expand()
    |> String.replace_prefix("/var/", "/private/var/")
  end
end
