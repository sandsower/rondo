defmodule Rondo.ReleaseLoopTest do
  use Rondo.TestSupport

  alias Rondo.{Linear.Issue, ReleaseLoop, RunLedger}

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), {:fake_linear_client, :fetch_candidate_issues})
      {:ok, []}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fake_linear_client, :fetch_issues_by_states, states})
      {:ok, []}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fake_linear_client, :fetch_issue_states_by_ids, issue_ids})
      {:ok, []}
    end

    def fetch_issue_contexts_by_ids(issue_ids) do
      send(self(), {:fake_linear_client, :fetch_issue_contexts_by_ids, issue_ids})
      {:ok, []}
    end

    def graphql(query, variables) do
      send(self(), {:fake_linear_client, :graphql, query, variables})

      cond do
        String.contains?(query, "issueUpdate") ->
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}

        String.contains?(query, "commentCreate") ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

        String.contains?(query, "RondoResolveStateId") ->
          state_id = Process.get({__MODULE__, :state_id}, "state-1")

          {:ok, %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => state_id}]}}}}}}

        true ->
          {:ok, %{"data" => %{}}}
      end
    end
  end

  setup do
    previous_linear_client_module = Application.get_env(:rondo, :linear_client_module)
    Application.put_env(:rondo, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      case previous_linear_client_module do
        nil -> Application.delete_env(:rondo, :linear_client_module)
        module -> Application.put_env(:rondo, :linear_client_module, module)
      end

      Process.delete({FakeLinearClient, :state_id})
    end)

    :ok
  end

  test "returns skip when no PR is found for the branch" do
    write_workflow_file!(Workflow.workflow_file_path(),
      release_loop_enabled: true
    )

    issue = %Issue{
      id: "issue-no-pr",
      identifier: "MT-NO-PR",
      title: "No PR found",
      state: "In Progress",
      branch_name: "feature/no-pr"
    }

    assert {:skip, :no_pr, _ledger} =
             ReleaseLoop.inspect(issue, repo: "sandsower/rondo", runner: release_loop_runner("[]"))
  end

  test "treats conflicting mergeability as recovery work and records conflict evidence" do
    pr = pr_map(42, "feature/conflicting-branch", "Conflict recovery", review_decision: "APPROVED", mergeable: "CONFLICTING", merge_state_status: "DIRTY")

    source_json =
      review_snapshot_json(pr,
        reviews: [],
        comments: [],
        inline_comments: [],
        conflict_files: ["elixir/lib/rondo/release_loop.ex", "elixir/lib/rondo/orchestrator.ex"],
        checks: %{state: "SUCCESS", conclusion: "SUCCESS", entries: [%{name: "ci", state: "SUCCESS", conclusion: "SUCCESS"}]}
      )

    workspace_root = tmp_dir("release-loop-conflict")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      release_loop_enabled: true,
      release_loop_pr_review_source: shell_print_json(source_json)
    )

    issue = %Issue{
      id: "issue-conflict-recovery",
      identifier: "MT-CONFLICT",
      title: "Conflict recovery",
      state: "In Progress",
      branch_name: "feature/conflicting-branch"
    }

    {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root, random_suffix: "conflict001")

    assert {:ok, decision, ledger} =
             ReleaseLoop.inspect(issue,
               repo: "sandsower/rondo",
               ledger: ledger,
               runner: release_loop_runner(Jason.encode!([pr]), source_json)
             )

    assert decision.action == :fix
    assert decision.recovery_kind == :conflict
    assert decision.guidance =~ "Mergeability conflict"
    assert decision.guidance =~ "merge/rebase conflict"

    payload = checkpoint_payload(ledger, "release_loop_plan")
    assert payload["pr"]["url"] == "https://github.com/sandsower/rondo/pull/42"
    assert payload["recovery_kind"] == "conflict"
    assert payload["conflict_files"] == ["elixir/lib/rondo/release_loop.ex", "elixir/lib/rondo/orchestrator.ex"]
    assert payload["feedback_comment_ids"] == []
    assert payload["mergeable"] == "CONFLICTING"
  end

  test "includes actionable inline bot feedback, posts a review reply, and records comment ids" do
    pr = pr_map(42, "feature/review-loop", "Fix review feedback", review_decision: "REVIEW_REQUIRED", mergeable: "UNKNOWN", merge_state_status: "DIRTY")

    source_json =
      review_snapshot_json(pr,
        reviews: [],
        comments: [],
        inline_comments: [
          %{id: "c1", body: "Please rename this helper to match the new flow.", path: "elixir/lib/rondo/example.ex", line: 12, author: %{login: "code-rabbit[bot]"}}
        ],
        checks: %{state: "PENDING", conclusion: nil, entries: [%{name: "ci", state: "PENDING", conclusion: nil}]}
      )

    workspace_root = tmp_dir("release-loop-review")
    reply_body_file = tmp_file("release-loop-reply-body")
    reply_comment_file = tmp_file("release-loop-reply-comment")
    update_command = "printf '%s' \"$RONDO_PR_REVIEW_REPLY_BODY\" > #{reply_body_file} && printf '%s' \"$RONDO_PR_REVIEW_COMMENT_ID\" > #{reply_comment_file}"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      release_loop_enabled: true,
      release_loop_pr_review_source: shell_print_json(source_json),
      release_loop_pr_review_update: update_command
    )

    issue = %Issue{
      id: "issue-inline-feedback",
      identifier: "MT-REVIEW-INLINE",
      title: "Inline feedback",
      state: "In Progress",
      branch_name: "feature/review-loop"
    }

    {:ok, ledger} = RunLedger.create_run(issue, workspace_root: workspace_root, random_suffix: "review001")

    assert {:ok, decision, ledger} =
             ReleaseLoop.inspect(issue,
               repo: "sandsower/rondo",
               ledger: ledger,
               runner: release_loop_runner(Jason.encode!([pr]), source_json)
             )

    assert decision.action == :fix
    assert decision.recovery_kind == :review_feedback
    assert Enum.any?(decision.feedback_queue, &(&1.kind == "inline"))
    assert File.read!(reply_body_file) =~ "addressing PR recovery"
    assert File.read!(reply_comment_file) == "c1"

    payload = checkpoint_payload(ledger, "release_loop_plan")
    assert payload["recovery_kind"] == "review_feedback"
    assert payload["feedback_comment_ids"] == ["c1"]
    assert payload["pr"]["number"] == 42
  end

  test "treats requested changes as blocking feedback" do
    pr = pr_map(7, "feature/requested-changes", "Requested changes", review_decision: "CHANGES_REQUESTED", mergeable: "UNKNOWN", merge_state_status: "DIRTY")

    source_json =
      review_snapshot_json(pr,
        reviews: [%{state: "CHANGES_REQUESTED", body: "Please split this into smaller steps.", author: %{login: "reviewer"}}],
        comments: [],
        inline_comments: [],
        checks: %{state: "SUCCESS", conclusion: "SUCCESS", entries: []}
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      release_loop_enabled: true,
      release_loop_pr_review_source: shell_print_json(source_json)
    )

    issue = %Issue{
      id: "issue-requested-changes",
      identifier: "MT-REQUESTED-CHANGES",
      title: "Requested changes",
      state: "In Progress",
      branch_name: "feature/requested-changes"
    }

    assert {:ok, decision, _ledger} =
             ReleaseLoop.inspect(issue, repo: "sandsower/rondo", runner: release_loop_runner(Jason.encode!([pr]), source_json))

    assert decision.action == :fix
    assert Enum.any?(decision.feedback_queue, &(&1.kind == "review"))
  end

  test "waits while checks are pending" do
    pr = pr_map(8, "feature/pending-checks", "Pending checks", review_decision: "APPROVED", mergeable: "UNKNOWN", merge_state_status: "BEHIND")

    source_json =
      review_snapshot_json(pr,
        reviews: [],
        comments: [],
        inline_comments: [],
        checks: %{state: "PENDING", conclusion: nil, entries: [%{name: "ci", state: "PENDING", conclusion: nil}]}
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      release_loop_enabled: true,
      release_loop_wait_interval_seconds: 9,
      release_loop_pr_review_source: shell_print_json(source_json)
    )

    issue = %Issue{
      id: "issue-pending-checks",
      identifier: "MT-PENDING-CHECKS",
      title: "Pending checks",
      state: "In Progress",
      branch_name: "feature/pending-checks"
    }

    assert {:ok, decision, _ledger} =
             ReleaseLoop.inspect(issue, repo: "sandsower/rondo", runner: release_loop_runner(Jason.encode!([pr]), source_json))

    assert decision.action == :wait
    assert decision.wait_interval_seconds == 9
  end

  test "skips automated closeout when PR risk exceeds the automation threshold" do
    pr = pr_map(9, "feature/high-risk", "High risk PR", review_decision: "APPROVED", mergeable: "MERGEABLE", merge_state_status: "CLEAN")

    source_json =
      review_snapshot_json(pr,
        reviews: [%{state: "APPROVED", body: "Looks good.", author: %{login: "reviewer"}}],
        comments: [],
        inline_comments: [],
        checks: %{state: "SUCCESS", conclusion: "SUCCESS", entries: [%{name: "ci", state: "SUCCESS", conclusion: "SUCCESS"}]}
      )

    workspace_root = tmp_dir("release-loop-risk-skip")
    workspace = Path.join(workspace_root, "MT-RISK-SKIP")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      release_loop_enabled: true,
      release_loop_max_pr_risk_level: "low",
      release_loop_pr_review_source: shell_print_json(source_json)
    )

    issue = %Issue{
      id: "issue-risk-skip",
      identifier: "MT-RISK-SKIP",
      title: "High risk PR",
      state: "In Progress",
      branch_name: "feature/high-risk"
    }

    runner =
      release_loop_runner(Jason.encode!([pr]), source_json,
        git: %{
          :rev_parse_head => {"head-sha", 0},
          :merge_base => {"", 1},
          :head_parent => {"base-sha", 0},
          {:name_only, "base-sha", "head-sha"} => {"elixir/config/runtime.exs\nelixir/lib/rondo/release_loop.ex\n", 0},
          {:numstat, "base-sha", "head-sha"} => {"24\t2\telixir/config/runtime.exs\n88\t10\telixir/lib/rondo/release_loop.ex\n", 0}
        }
      )

    assert {:skip, {:risk_above_threshold, assessment}, _ledger} =
             ReleaseLoop.inspect(issue, repo: "sandsower/rondo", workspace: workspace, runner: runner)

    assert assessment.level == "high"
    assert assessment.threshold == "low"
    assert assessment.allowed == false
    assert assessment.source == "git-diff"
    assert Enum.any?(assessment.evidence.changed_paths, &String.contains?(&1, "release_loop.ex"))
  end

  test "runs configured gates before closeout and fails when a gate fails" do
    pr = pr_map(9, "feature/gate-failure", "Gate failure", review_decision: "APPROVED", mergeable: "MERGEABLE", merge_state_status: "CLEAN")

    source_json =
      review_snapshot_json(pr,
        reviews: [%{state: "APPROVED", body: "Looks good.", author: %{login: "reviewer"}}],
        comments: [],
        inline_comments: [],
        checks: %{state: "SUCCESS", conclusion: "SUCCESS", entries: [%{name: "ci", state: "SUCCESS", conclusion: "SUCCESS"}]}
      )

    workspace_root = tmp_dir("release-loop-gate-failure")
    workspace = Path.join(workspace_root, "MT-GATE-FAIL")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      release_loop_enabled: true,
      release_loop_pr_review_source: shell_print_json(source_json),
      action_policy_command: fake_action_policy("allow"),
      gates: [%{name: "format", command: "exit 3", timeout_ms: 1000}]
    )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    issue = %Issue{
      id: "issue-gate-failure",
      identifier: "MT-GATE-FAIL",
      title: "Gate failure",
      state: "In Progress",
      branch_name: "feature/gate-failure"
    }

    runner = release_loop_runner(Jason.encode!([pr]), source_json)
    {:ok, closeout_ledger} = RunLedger.create_run(issue, workspace_root: workspace_root, workspace: workspace)

    assert {:ok, decision, _ledger} =
             ReleaseLoop.inspect(issue, repo: "sandsower/rondo", runner: runner)

    assert decision.action == :merge

    assert {:error, {:release_loop_gate_failed, summary}, _ledger} =
             ReleaseLoop.execute_closeout(issue, decision,
               ledger: closeout_ledger,
               repo: "sandsower/rondo",
               workspace: workspace,
               runner: runner,
               release_loop: release_loop_config()
             )

    assert summary.status == :fail
  end

  test "merges green PRs and transitions the issue to done" do
    pr = pr_map(10, "feature/green-closeout", "Ready to merge", review_decision: "APPROVED", mergeable: "MERGEABLE", merge_state_status: "CLEAN")

    source_json =
      review_snapshot_json(pr,
        reviews: [%{state: "APPROVED", body: "Looks good.", author: %{login: "reviewer"}}],
        comments: [],
        inline_comments: [],
        checks: %{state: "SUCCESS", conclusion: "SUCCESS", entries: [%{name: "ci", state: "SUCCESS", conclusion: "SUCCESS"}]}
      )

    workspace_root = tmp_dir("release-loop-closeout")
    workspace = Path.join(workspace_root, "MT-GREEN-CLOSEOUT")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    issue = %Issue{
      id: "issue-green-closeout",
      identifier: "MT-GREEN",
      title: "Green closeout",
      state: "In Progress",
      branch_name: "feature/green-closeout"
    }

    Application.put_env(:rondo, :memory_tracker_issues, [issue])
    Application.put_env(:rondo, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:rondo, :memory_tracker_issues)
      Application.delete_env(:rondo, :memory_tracker_recipient)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      release_loop_enabled: true,
      release_loop_pr_review_source: shell_print_json(source_json),
      action_policy_command: fake_action_policy("allow"),
      gates: [%{name: "format", command: "exit 0", timeout_ms: 1000}]
    )

    runner = release_loop_runner(Jason.encode!([pr]), source_json)
    {:ok, closeout_ledger} = RunLedger.create_run(issue, workspace_root: workspace_root, workspace: workspace)

    assert {:ok, decision, _ledger} =
             ReleaseLoop.inspect(issue, repo: "sandsower/rondo", runner: runner)

    assert decision.action == :merge

    assert {:ok, result, _ledger} =
             ReleaseLoop.execute_closeout(issue, decision,
               ledger: closeout_ledger,
               repo: "sandsower/rondo",
               workspace: workspace,
               runner: runner,
               release_loop: release_loop_config()
             )

    assert result.closed_out?
    assert_received {:memory_tracker_state_update, "issue-green-closeout", "Done"}
  end

  test "policy-denied merge fails closed" do
    pr = pr_map(11, "feature/policy-denied", "Policy denied", review_decision: "APPROVED", mergeable: "MERGEABLE", merge_state_status: "CLEAN")

    source_json =
      review_snapshot_json(pr,
        reviews: [%{state: "APPROVED", body: "Approved.", author: %{login: "reviewer"}}],
        comments: [],
        inline_comments: [],
        checks: %{state: "SUCCESS", conclusion: "SUCCESS", entries: []}
      )

    workspace_root = tmp_dir("release-loop-policy-denied")
    workspace = Path.join(workspace_root, "MT-POLICY-DENIED")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    issue = %Issue{
      id: "issue-policy-denied",
      identifier: "MT-POLICY-DENIED",
      title: "Policy denied",
      state: "In Progress",
      branch_name: "feature/policy-denied"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      release_loop_enabled: true,
      release_loop_pr_review_source: shell_print_json(source_json),
      action_policy_command: fake_action_policy("deny")
    )

    runner = release_loop_runner(Jason.encode!([pr]), source_json)
    {:ok, closeout_ledger} = RunLedger.create_run(issue, workspace_root: workspace_root, workspace: workspace)

    assert {:ok, decision, _ledger} =
             ReleaseLoop.inspect(issue, repo: "sandsower/rondo", runner: runner)

    assert decision.action == :merge

    assert {:error, {:action_policy_denied, _envelope}, _ledger} =
             ReleaseLoop.execute_closeout(issue, decision,
               ledger: closeout_ledger,
               repo: "sandsower/rondo",
               workspace: workspace,
               runner: runner,
               release_loop: release_loop_config()
             )
  end

  defp release_loop_runner(pr_list_json, source_json \\ nil, opts \\ []) do
    git_responses = Keyword.get(opts, :git, %{})

    fn
      "gh", ["pr", "list" | _], _opts ->
        {pr_list_json, 0}

      "gh", ["pr", "merge" | _], _opts ->
        {"merged", 0}

      "git", ["rev-parse", "HEAD"], _opts ->
        Map.get(git_responses, :rev_parse_head, {"HEAD", 0})

      "git", ["merge-base", "HEAD", "origin/main"], _opts ->
        Map.get(git_responses, :merge_base, {"", 1})

      "git", ["rev-parse", "HEAD^"], _opts ->
        Map.get(git_responses, :head_parent, {"", 1})

      "git", ["diff", "--name-only", base_ref, head_ref], _opts ->
        Map.get(git_responses, {:name_only, base_ref, head_ref}, {"", 0})

      "git", ["diff", "--numstat", base_ref, head_ref], _opts ->
        Map.get(git_responses, {:numstat, base_ref, head_ref}, {"", 0})

      "sh", ["-lc", command], opts ->
        if source_json && String.contains?(command, source_json) do
          {source_json, 0}
        else
          System.cmd("sh", ["-lc", command], opts)
        end

      cmd, args, opts ->
        System.cmd(cmd, args, opts)
    end
  end

  defp pr_map(number, branch, title, opts) do
    %{
      number: number,
      url: "https://github.com/sandsower/rondo/pull/#{number}",
      title: title,
      state: "OPEN",
      headRefName: branch,
      baseRefName: "main",
      isDraft: false,
      mergeable: Keyword.get(opts, :mergeable, "MERGEABLE"),
      mergeStateStatus: Keyword.get(opts, :merge_state_status, "CLEAN"),
      reviewDecision: Keyword.get(opts, :review_decision, "REVIEW_REQUIRED")
    }
  end

  defp review_snapshot_json(pr, extra) do
    Map.merge(
      %{
        pr: pr,
        reviews: Keyword.get(extra, :reviews, []),
        comments: Keyword.get(extra, :comments, []),
        inline_comments: Keyword.get(extra, :inline_comments, []),
        conflict_files: Keyword.get(extra, :conflict_files, []),
        checks: Keyword.get(extra, :checks, %{state: "SUCCESS", conclusion: "SUCCESS", entries: []}),
        review_decision: Map.get(pr, :reviewDecision),
        mergeable: Map.get(pr, :mergeable),
        merge_state_status: Map.get(pr, :mergeStateStatus)
      },
      %{}
    )
    |> Jason.encode!()
  end

  defp checkpoint_payload(ledger, kind) do
    manifest = Jason.decode!(File.read!(ledger.manifest_path))
    checkpoint = Enum.find(manifest["checkpoints"], &(&1["kind"] == kind))

    Path.join(ledger.run_dir, checkpoint["path"])
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("payload")
  end

  defp shell_print_json(json) do
    "printf '%s' '#{json}'"
  end

  defp fake_action_policy(decision) do
    script = tmp_file("release-loop-action-policy")

    File.write!(script, """
    #!/bin/sh
    printf '{"decision":"#{decision}","action":"merge","mode":"unattended-auto","classes":[],"log_level":"info","requires_human":false,"reason":"test #{decision}","matched_rules":[]}'
    """)

    File.chmod!(script, 0o755)
    script
  end

  defp release_loop_config do
    %{run_configured_gates_before_push: true, closeout: %{merge: %{mode: "auto", method: "merge", delete_branch: true}}}
  end

  defp tmp_file(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(path)
    path
  end
end
