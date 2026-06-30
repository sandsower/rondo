defmodule Rondo.ReleaseLoop do
  # credo:disable-for-this-file
  @moduledoc """
  Native review-response / babysit / release-loop orchestration.
  """

  import Kernel, except: [inspect: 1]

  require Logger

  alias Rondo.{ActionPolicy, Config, Gates, Linear.Issue, RunLedger, SideEffectPolicy, Tracker}
  alias Rondo.GitHub.PullRequest

  @review_reply_limit 3
  @risk_levels %{low: 1, medium: 2, high: 3}

  @dialyzer {:nowarn_function, execute_closeout: 3}
  @dialyzer {:nowarn_function, post_reply_via_command: 6}
  @dialyzer {:nowarn_function, parse_git_stat_int: 1}
  @dialyzer {:nowarn_function, classify_pr_risk: 2}
  @dialyzer {:nowarn_function, docs_or_test_only_paths?: 1}

  @type loop_result ::
          {:ok, map(), RunLedger.t() | nil}
          | {:skip, term(), RunLedger.t() | nil}
          | {:error, term(), RunLedger.t() | nil}

  @spec inspect(Issue.t(), keyword()) :: loop_result()
  def inspect(%Issue{} = issue, opts \\ []) do
    ledger = Keyword.get(opts, :ledger)
    config = Keyword.get(opts, :release_loop) || Config.release_loop() || %{}
    repo = Keyword.get(opts, :repo, Config.tracker_repo())

    cond do
      !Map.get(config, :enabled, false) ->
        {:skip, :disabled, ledger}

      is_nil(repo) or String.trim(to_string(repo)) == "" ->
        {:skip, :missing_repo, ledger}

      is_nil(issue.branch_name) or String.trim(issue.branch_name) == "" ->
        {:skip, :missing_branch, ledger}

      true ->
        with {:ok, pr} <- find_pull_request(repo, issue.branch_name, opts),
             {:ok, snapshot} <- fetch_review_snapshot(repo, pr, config, opts),
             {:ok, ledger} <- record_snapshot(ledger, issue, pr, snapshot, config),
             {:ok, risk_result, ledger} <- assess_risk_gate(issue, pr, snapshot, config, opts, ledger) do
          case risk_result do
            {:skip, reason} -> {:skip, reason, ledger}
            risk_assessment -> plan_action(issue, pr, snapshot, config, opts, ledger, risk_assessment)
          end
        else
          {:skip, reason} -> {:skip, reason, ledger}
          {:error, reason} -> {:error, reason, ledger}
        end
    end
  end

  @spec execute_closeout(Issue.t(), map(), keyword()) ::
          {:ok, map(), RunLedger.t() | nil}
          | {:skip, term(), RunLedger.t() | nil}
          | {:error, term(), RunLedger.t() | nil}
  def execute_closeout(%Issue{} = issue, decision, opts \\ []) when is_map(decision) do
    ledger = Keyword.get(opts, :ledger)
    config = Keyword.get(opts, :release_loop) || Config.release_loop() || %{}
    workspace = Keyword.get(opts, :workspace)
    pr = Map.fetch!(decision, :pr)
    review_snapshot = Map.fetch!(decision, :review_snapshot)

    case Map.get(decision, :risk_assessment) do
      %{allowed: false} = assessment ->
        {:skip, {:risk_above_threshold, assessment}, record_risk_skip(ledger, issue, pr, assessment)}

      _ ->
        with {:ok, ledger} <- maybe_run_release_gates(workspace, decision, config, opts, ledger),
             {:ok, ledger} <- authorize_merge(issue, pr, config, opts, ledger),
             :ok <- merge_pull_request(pr, config, opts),
             :ok <- transition_issue_to_done(issue, config, opts),
             {:ok, ledger} <- record_closeout_success(ledger, issue, pr, review_snapshot, config) do
          {:ok, Map.put(decision, :closed_out?, true), ledger}
        else
          {:skip, reason, ledger} -> {:skip, reason, ledger}
          {:error, reason, ledger} -> {:error, reason, ledger}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec build_review_response_prompt(map(), map()) :: String.t()
  def build_review_response_prompt(pr, snapshot) when is_map(pr) and is_map(snapshot) do
    feedback = Map.get(snapshot, :feedback_queue, [])
    checks = Map.get(snapshot, :checks, %{})
    mergeable = Map.get(snapshot, :mergeable)
    merge_state_status = Map.get(snapshot, :merge_state_status)
    conflict_files = Map.get(snapshot, :conflict_files, [])
    recovery_kind = recovery_kind(snapshot)

    feedback_block =
      feedback
      |> Enum.map_join("\n", fn item ->
        "- #{Map.get(item, :kind, "comment")}: #{Map.get(item, :summary, "")}" |> String.trim_trailing()
      end)

    conflict_block =
      if conflicting_mergeability?(mergeable, merge_state_status) do
        conflict_file_block =
          conflict_files
          |> Enum.map_join("\n", fn path -> "- #{path}" end)

        """
        Mergeability conflict:
        - mergeable: #{string_value(mergeable) || "unknown"}
        - merge_state_status: #{string_value(merge_state_status) || "unknown"}
        - conflict files:
        #{if conflict_file_block == "", do: "- none", else: conflict_file_block}
        """
      else
        ""
      end

    """
    You are handling PR recovery and review response for this ticket.

    PR: #{Map.get(pr, :number)} #{Map.get(pr, :url)}
    Branch: #{Map.get(pr, :head_ref_name, "")}
    Recovery kind: #{recovery_kind || "none"}

    Current checks: #{Kernel.inspect(checks)}

    #{conflict_block}
    Actionable feedback queue:
    #{if feedback_block == "", do: "- none", else: feedback_block}

    Tasks:
    - If the PR is conflicting, resolve the merge/rebase conflict in the workspace, rerun verification, and push the updated branch.
    - If a comment is incorrect or not actionable, post a concise justified pushback reply.
    - Fix actionable feedback in the workspace.
    - Re-run the configured gates before any push/merge boundary.
    - Keep the loop going until the PR is green or the configured merge policy blocks closeout.
    """
  end

  @spec closeout_state(map()) :: String.t()
  def closeout_state(config) when is_map(config) do
    config
    |> get_in([:closeout, :merge, :mode])
    |> case do
      "ask" -> "review"
      "deny" -> "review"
      _ -> "merge"
    end
  end

  defp find_pull_request(repo, branch, opts) do
    case PullRequest.find_open_by_branch(repo, branch, opts) do
      {:ok, nil} -> {:skip, :no_pr}
      {:ok, pr} when is_map(pr) -> {:ok, normalize_pr(pr)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_review_snapshot(repo, pr, config, opts) do
    source = Map.get(config, :pr_review_source)

    if is_binary(source) and String.trim(source) != "" do
      run_review_source_command(source, repo, pr, opts)
    else
      default_review_snapshot(repo, pr, opts)
    end
  end

  defp default_review_snapshot(repo, pr, opts) do
    with {:ok, pr_view} <- PullRequest.view(Map.fetch!(pr, :number), repo, opts),
         {:ok, inline_comments} <- PullRequest.inline_comments(Map.fetch!(pr, :number), repo, opts) do
      {:ok, build_snapshot(pr_view, inline_comments)}
    end
  end

  defp run_review_source_command(command, repo, pr, opts) do
    env = review_env(repo, pr, opts)
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    case run_shell_command(command, env, runner) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, decoded} when is_map(decoded) -> {:ok, normalize_snapshot(decoded)}
          {:ok, _other} -> {:error, :review_source_unexpected_payload}
          {:error, %Jason.DecodeError{} = reason} -> {:error, {:review_source_decode_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_snapshot(pr_view, inline_comments) do
    %{
      pr: normalize_pr(pr_view),
      reviews: normalize_reviews(Map.get(pr_view, "reviews", [])),
      comments: normalize_comments(Map.get(pr_view, "comments", [])),
      inline_comments: normalize_inline_comments(inline_comments),
      conflict_files: [],
      checks: normalize_checks(Map.get(pr_view, "statusCheckRollup", %{})),
      review_decision: Map.get(pr_view, "reviewDecision"),
      mergeable: Map.get(pr_view, "mergeable"),
      merge_state_status: Map.get(pr_view, "mergeStateStatus")
    }
    |> normalize_snapshot()
  end

  defp normalize_snapshot(snapshot) when is_map(snapshot) do
    %{
      pr: normalize_pr(first_present(snapshot, [:pr, "pr"]) || snapshot),
      reviews: normalize_reviews(first_present(snapshot, [:reviews, "reviews"]) || []),
      comments: normalize_comments(first_present(snapshot, [:comments, "comments"]) || []),
      inline_comments: normalize_inline_comments(first_present(snapshot, [:inline_comments, "inline_comments"]) || []),
      conflict_files: normalize_conflict_files(first_present(snapshot, [:conflict_files, "conflict_files"]) || []),
      checks: normalize_checks(first_present(snapshot, [:checks, "checks"]) || %{}),
      review_decision: first_present(snapshot, [:review_decision, "review_decision", "reviewDecision"]),
      mergeable: first_present(snapshot, [:mergeable, "mergeable"]),
      merge_state_status: first_present(snapshot, [:merge_state_status, "merge_state_status", "mergeStateStatus"])
    }
  end

  defp normalize_pr(nil), do: %{}

  defp normalize_pr(pr) when is_map(pr) do
    %{
      number: int_value(first_present(pr, [:number, "number"])),
      url: string_value(first_present(pr, [:url, "url"])),
      title: string_value(first_present(pr, [:title, "title"])),
      state: string_value(first_present(pr, [:state, "state"])),
      head_ref_name: string_value(first_present(pr, [:head_ref_name, "head_ref_name", "headRefName"])),
      base_ref_name: string_value(first_present(pr, [:base_ref_name, "base_ref_name", "baseRefName"])),
      is_draft: boolean_value(first_present(pr, [:is_draft, "is_draft", "isDraft"])),
      mergeable: string_value(first_present(pr, [:mergeable, "mergeable"])),
      merge_state_status: string_value(first_present(pr, [:merge_state_status, "merge_state_status", "mergeStateStatus"])),
      review_decision: string_value(first_present(pr, [:review_decision, "review_decision", "reviewDecision"]))
    }
    |> drop_nil_values()
  end

  defp normalize_reviews(reviews) when is_list(reviews) do
    Enum.map(reviews, fn review ->
      %{
        author: author_login(review),
        state: string_value(Map.get(review, "state")),
        body: string_value(Map.get(review, "body")),
        submitted_at: string_value(Map.get(review, "submittedAt")),
        url: string_value(Map.get(review, "url"))
      }
      |> drop_nil_values()
    end)
  end

  defp normalize_comments(comments) when is_list(comments) do
    Enum.map(comments, fn comment ->
      %{
        id: string_value(Map.get(comment, "id")),
        author: author_login(comment),
        body: string_value(Map.get(comment, "body")),
        created_at: string_value(Map.get(comment, "createdAt")),
        url: string_value(Map.get(comment, "url"))
      }
      |> drop_nil_values()
    end)
  end

  defp normalize_inline_comments(comments) when is_list(comments) do
    Enum.map(comments, fn comment ->
      %{
        id: string_value(Map.get(comment, "id")),
        author: author_login(comment),
        body: string_value(Map.get(comment, "body")),
        path: string_value(Map.get(comment, "path")),
        line: int_value(Map.get(comment, "line") || Map.get(comment, "originalLine")),
        start_line: int_value(Map.get(comment, "startLine") || Map.get(comment, "originalStartLine")),
        url: string_value(Map.get(comment, "url"))
      }
      |> drop_nil_values()
    end)
  end

  defp normalize_conflict_files(files) when is_list(files) do
    files
    |> Enum.map(&string_value/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_conflict_files(_files), do: []

  defp normalize_checks(%{} = rollup) do
    entries = Map.get(rollup, "contexts", []) || Map.get(rollup, :contexts, [])

    %{
      state: string_value(Map.get(rollup, "state")),
      conclusion: string_value(Map.get(rollup, "conclusion")),
      entries:
        Enum.map(entries, fn entry ->
          %{
            name: string_value(Map.get(entry, "context") || Map.get(entry, "name")),
            state: string_value(Map.get(entry, "state")),
            conclusion: string_value(Map.get(entry, "conclusion")),
            url: string_value(Map.get(entry, "targetUrl") || Map.get(entry, "url"))
          }
          |> drop_nil_values()
        end)
    }
    |> drop_nil_values()
  end

  defp normalize_checks(_other), do: %{}

  defp plan_action(issue, pr, snapshot, config, opts, ledger, risk_assessment) do
    feedback_queue = feedback_queue(snapshot)
    checks = Map.get(snapshot, :checks, %{})
    _review_decision = Map.get(snapshot, :review_decision)
    mergeable = Map.get(snapshot, :mergeable)
    merge_state_status = Map.get(snapshot, :merge_state_status)
    recovery_kind = recovery_kind(snapshot)

    decision =
      cond do
        recovery_kind != nil ->
          %{
            action: :fix,
            pr: pr,
            review_snapshot: snapshot,
            feedback_queue: feedback_queue,
            feedback_comment_ids: feedback_comment_ids(snapshot),
            conflict_files: Map.get(snapshot, :conflict_files, []),
            recovery_kind: recovery_kind,
            checks: checks,
            mergeable: mergeable,
            merge_state_status: merge_state_status,
            risk_assessment: risk_assessment,
            guidance: build_review_response_prompt(pr, snapshot),
            reply_preview: build_reply_preview(issue, pr, snapshot)
          }

        checks_pending?(checks) or mergeable_pending(mergeable, merge_state_status) ->
          %{
            action: :wait,
            pr: pr,
            review_snapshot: snapshot,
            feedback_queue: feedback_queue,
            feedback_comment_ids: feedback_comment_ids(snapshot),
            conflict_files: Map.get(snapshot, :conflict_files, []),
            checks: checks,
            mergeable: mergeable,
            merge_state_status: merge_state_status,
            risk_assessment: risk_assessment,
            wait_interval_seconds: Map.get(config, :wait_interval_seconds, Config.release_loop_wait_interval_seconds())
          }

        green_to_close?(snapshot) ->
          %{
            action: :merge,
            pr: pr,
            review_snapshot: snapshot,
            feedback_queue: feedback_queue,
            feedback_comment_ids: feedback_comment_ids(snapshot),
            conflict_files: Map.get(snapshot, :conflict_files, []),
            checks: checks,
            mergeable: mergeable,
            merge_state_status: merge_state_status,
            risk_assessment: risk_assessment,
            closeout_state: closeout_state(config)
          }

        true ->
          %{
            action: :wait,
            pr: pr,
            review_snapshot: snapshot,
            feedback_queue: feedback_queue,
            feedback_comment_ids: feedback_comment_ids(snapshot),
            conflict_files: Map.get(snapshot, :conflict_files, []),
            checks: checks,
            mergeable: mergeable,
            merge_state_status: merge_state_status,
            risk_assessment: risk_assessment,
            wait_interval_seconds: Map.get(config, :wait_interval_seconds, Config.release_loop_wait_interval_seconds())
          }
      end

    ledger = record_planned_action(ledger, issue, pr, decision, config)

    maybe_post_reply(decision, Keyword.put(opts, :ledger, ledger))

    {:ok, decision, ledger}
  end

  defp maybe_post_reply(%{action: :fix, reply_preview: reply_preview, review_snapshot: snapshot, pr: pr} = decision, opts) do
    ledger = Keyword.get(opts, :ledger)
    config = Keyword.get(opts, :release_loop) || Config.release_loop() || %{}
    repo = Keyword.get(opts, :repo, Config.tracker_repo())

    record_reply_activity(ledger, decision, :prepared, %{reply_preview: reply_preview})

    case Map.get(config, :pr_review_update) do
      command when is_binary(command) ->
        if String.trim(command) == "" do
          record_reply_activity(ledger, decision, :printed, %{reply_preview: reply_preview})
          decision
        else
          top_comment = actionable_comment(snapshot)

          case post_reply_via_command(command, repo, pr, top_comment, reply_preview, opts) do
            {:ok, _output} -> record_reply_activity(ledger, decision, :posted, %{reply_preview: reply_preview, comment_id: Map.get(top_comment, :id)})
            {:error, reason} -> record_reply_activity(ledger, decision, :failed, %{reply_preview: reply_preview, comment_id: Map.get(top_comment, :id), error: Kernel.inspect(reason)})
          end

          decision
        end

      _ ->
        record_reply_activity(ledger, decision, :printed, %{reply_preview: reply_preview})
        decision
    end
  end

  defp maybe_post_reply(decision, _opts), do: decision

  defp post_reply_via_command(command, repo, pr, comment, body, opts) do
    env =
      repo
      |> review_env(pr, opts)
      |> Map.put("RONDO_PR_REVIEW_REPLY_BODY", body || "")
      |> Map.put("RONDO_PR_REVIEW_COMMENT_ID", Map.get(comment, :id, ""))

    runner = Keyword.get(opts, :runner, &System.cmd/3)

    case run_shell_command(command, env, runner) do
      {:ok, output} ->
        {:ok, output}

      {:error, reason} ->
        Logger.warning("Review reply command failed repo=#{repo} pr=#{Map.get(pr, :number)} reason=#{Kernel.inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_run_release_gates(nil, _decision, _config, _opts, ledger), do: {:ok, ledger}

  defp maybe_run_release_gates(workspace, %{action: :merge} = decision, config, opts, ledger) when is_binary(workspace) do
    if Map.get(config, :run_configured_gates_before_push, true) do
      case Gates.run(Config.gates(), workspace,
             run_dir: Map.get(ledger || %{}, :run_dir),
             execution_id: "release-loop-merge",
             action_policy: true,
             action_policy_evaluator: &ActionPolicy.evaluate/3,
             worker_host: Keyword.get(opts, :worker_host)
           ) do
        {:ok, summary} ->
          ledger = record_release_gate_summary(ledger, decision, summary)
          {:ok, ledger}

        {:error, summary} when is_map(summary) ->
          ledger = record_release_gate_summary(ledger, decision, summary)
          {:error, {:release_loop_gate_failed, summary}, ledger}

        {:error, reason} ->
          {:error, {:release_loop_gate_error, reason}, ledger}
      end
    else
      {:ok, ledger}
    end
  end

  defp maybe_run_release_gates(_workspace, _decision, _config, _opts, ledger), do: {:ok, ledger}

  defp authorize_merge(issue, pr, _config, opts, ledger) do
    side_effect = %{
      action: "pr.merge",
      classes: ["git-remote"],
      label: "PR merge",
      operation: "Merge PR #{Map.get(pr, :number)} for #{issue.identifier || issue.id}",
      required: true,
      resume_safe: false,
      skip_behavior: "block",
      side_effect_id: "pr-merge:#{issue.id}:#{Map.get(pr, :number)}"
    }

    case SideEffectPolicy.evaluate(side_effect, ledger: ledger, workspace: Keyword.get(opts, :workspace), worker_host: Keyword.get(opts, :worker_host)) do
      {:ok, decision} ->
        {:ok, Map.get(decision, :ledger, ledger)}

      {:blocked, %{block_reason: :action_policy_requires_guidance, interrupt: interrupt} = decision} ->
        {:error, {:action_policy_guidance_required, interrupt}, Map.get(decision, :ledger, ledger)}

      {:blocked, %{block_reason: :action_policy_denied, envelope: envelope} = decision} ->
        {:error, {:action_policy_denied, envelope}, Map.get(decision, :ledger, ledger)}

      {:blocked, %{block_reason: {:action_policy_failed, reason}} = decision} ->
        {:error, {:action_policy_failed, reason}, Map.get(decision, :ledger, ledger)}
    end
  end

  defp merge_pull_request(pr, config, opts) do
    repo = Keyword.get(opts, :repo, Config.tracker_repo())
    merge_config = Map.get(config, :closeout, %{}) |> Map.get(:merge, %{})
    method = Map.get(merge_config, :method, "merge")
    delete_branch? = Map.get(merge_config, :delete_branch, true)

    case PullRequest.merge(Map.fetch!(pr, :number),
           repo: repo,
           method: method,
           delete_branch: delete_branch?,
           runner: Keyword.get(opts, :runner, &System.cmd/3)
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition_issue_to_done(%Issue{} = issue, config, _opts) do
    done_state = Map.get(config, :done_state, Config.release_loop_done_state())

    case Tracker.update_issue_state(issue.id, done_state) do
      :ok -> :ok
      {:error, reason} -> {:error, {:issue_state_transition_failed, reason}}
    end
  end

  defp record_snapshot(nil, _issue, _pr, _snapshot, _config), do: {:ok, nil}

  defp record_snapshot(%RunLedger{} = ledger, issue, pr, snapshot, _config) do
    payload = %{
      issue: issue.identifier || issue.id,
      pr: Map.take(pr, [:number, :url, :title, :head_ref_name, :base_ref_name]),
      review_decision: Map.get(snapshot, :review_decision),
      mergeable: Map.get(snapshot, :mergeable),
      merge_state_status: Map.get(snapshot, :merge_state_status),
      feedback_queue: feedback_queue(snapshot),
      feedback_comment_ids: feedback_comment_ids(snapshot),
      conflict_files: Map.get(snapshot, :conflict_files, []),
      recovery_kind: recovery_kind(snapshot),
      checks: Map.get(snapshot, :checks, %{}),
      action: plan_action_kind(snapshot)
    }

    case RunLedger.write_checkpoint(ledger, :release_loop_review_loaded, payload, source: %{loop: "babysit"}) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, reason}
    end
  end

  defp assess_risk_gate(issue, pr, _snapshot, config, opts, ledger) do
    threshold = Map.get(config, :max_pr_risk_level, Config.release_loop_max_pr_risk_level())
    workspace = Keyword.get(opts, :workspace)

    cond do
      is_nil(workspace) or String.trim(to_string(workspace)) == "" ->
        assessment = %{
          level: "unknown",
          threshold: threshold,
          allowed: true,
          source: "workspace_unavailable",
          evidence: %{reason: "workspace not provided"}
        }

        {:ok, assessment, record_risk_gate(ledger, issue, pr, assessment, :unavailable)}

      true ->
        with {:ok, surface} <- collect_pr_surface_area(workspace, ledger, opts) do
          risk_level = classify_pr_risk(surface.changed_paths, surface.numstat)
          allowed = risk_level_allowed?(risk_level, threshold)

          assessment = %{
            level: risk_level,
            threshold: threshold,
            allowed: allowed,
            source: surface.source,
            evidence: surface
          }

          ledger = record_risk_gate(ledger, issue, pr, assessment, if(allowed, do: :allowed, else: :blocked))

          if allowed do
            {:ok, assessment, ledger}
          else
            {:ok, {:skip, {:risk_above_threshold, assessment}}, ledger}
          end
        else
          {:error, reason} ->
            assessment = %{
              level: "unknown",
              threshold: threshold,
              allowed: false,
              source: "workspace_risk_assessment_failed",
              evidence: %{reason: Kernel.inspect(reason)}
            }

            ledger = record_risk_gate(ledger, issue, pr, assessment, :unavailable)
            {:ok, {:skip, {:risk_gate_unavailable, reason}}, ledger}
        end
    end
  end

  defp record_risk_gate(nil, _issue, _pr, _assessment, _status), do: nil

  defp record_risk_gate(%RunLedger{} = ledger, issue, pr, assessment, status) do
    payload = %{
      issue: issue.identifier || issue.id,
      pr: Map.take(pr, [:number, :url, :title, :head_ref_name, :base_ref_name]),
      status: status,
      level: Map.get(assessment, :level),
      threshold: Map.get(assessment, :threshold),
      allowed: Map.get(assessment, :allowed),
      source: Map.get(assessment, :source),
      evidence: Map.get(assessment, :evidence)
    }

    manifest_update = fn manifest ->
      update_in(manifest, ["release_loop"], fn release_loop ->
        Map.put(release_loop || %{}, "risk_assessment", assessment)
      end)
    end

    case RunLedger.write_checkpoint(ledger, :release_loop_risk_evaluated, payload,
           source: %{loop: "babysit"},
           manifest_update: manifest_update
         ) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Release loop risk checkpoint failed issue=#{issue.identifier || issue.id} reason=#{Kernel.inspect(reason)}")
        ledger
    end
  end

  defp record_risk_skip(nil, _issue, _pr, _assessment), do: nil

  defp record_risk_skip(%RunLedger{} = ledger, issue, pr, assessment) do
    payload = %{
      issue: issue.identifier || issue.id,
      pr: Map.take(pr, [:number, :url, :title, :head_ref_name, :base_ref_name]),
      level: Map.get(assessment, :level),
      threshold: Map.get(assessment, :threshold),
      allowed: Map.get(assessment, :allowed),
      source: Map.get(assessment, :source),
      evidence: Map.get(assessment, :evidence),
      status: "blocked"
    }

    manifest_update = fn manifest ->
      update_in(manifest, ["release_loop"], fn release_loop ->
        Map.put(release_loop || %{}, "risk_skip", payload)
      end)
    end

    case RunLedger.write_checkpoint(ledger, :release_loop_risk_skipped, payload,
           source: %{loop: "babysit"},
           manifest_update: manifest_update
         ) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Release loop risk skip checkpoint failed issue=#{issue.identifier || issue.id} reason=#{Kernel.inspect(reason)}")
        ledger
    end
  end

  defp record_reply_activity(nil, _decision, _status, _payload), do: nil

  defp record_reply_activity(%RunLedger{} = ledger, decision, status, payload) do
    checkpoint_payload =
      payload
      |> Map.put(:action, Map.get(decision, :action))
      |> Map.put(:reply_preview, Map.get(decision, :reply_preview))

    case RunLedger.write_checkpoint(ledger, :release_loop_reply_activity, checkpoint_payload, source: %{loop: "babysit", status: status}) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Release loop reply checkpoint failed status=#{status} reason=#{Kernel.inspect(reason)}")
        ledger
    end
  end

  defp collect_pr_surface_area(workspace, ledger, opts) when is_binary(workspace) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    with {:ok, head_ref} <- git_command(runner, workspace, ["rev-parse", "HEAD"]),
         {:ok, base_ref} <- resolve_pr_base_ref(runner, workspace, ledger, head_ref),
         {:ok, changed_paths_output} <- git_command(runner, workspace, ["diff", "--name-only", base_ref, head_ref]),
         {:ok, numstat_output} <- git_command(runner, workspace, ["diff", "--numstat", base_ref, head_ref]) do
      changed_paths = parse_git_paths(changed_paths_output)
      numstat = parse_git_numstat(numstat_output)

      {:ok,
       %{
         source: "git-diff",
         base_ref: base_ref,
         head_ref: head_ref,
         changed_paths: changed_paths,
         changed_file_count: length(changed_paths),
         numstat: numstat,
         additions: Enum.reduce(numstat, 0, &(&1.additions + &2)),
         deletions: Enum.reduce(numstat, 0, &(&1.deletions + &2))
       }}
    end
  end

  defp collect_pr_surface_area(_workspace, _ledger, _opts), do: {:error, :missing_workspace}

  defp resolve_pr_base_ref(runner, workspace, ledger, head_ref) do
    base_commit = get_in((ledger && ledger.manifest) || %{}, ["repo", "base_commit"])

    cond do
      is_binary(base_commit) and String.trim(base_commit) != "" ->
        {:ok, String.trim(base_commit)}

      true ->
        case git_command(runner, workspace, ["merge-base", "HEAD", "origin/main"]) do
          {:ok, base_ref} ->
            {:ok, base_ref}

          {:error, _reason} ->
            case git_command(runner, workspace, ["rev-parse", "HEAD^"]) do
              {:ok, fallback_ref} -> {:ok, fallback_ref}
              {:error, _reason} -> {:ok, head_ref}
            end
        end
    end
  end

  defp git_command(runner, workspace, args) do
    case runner.("git", args, cd: workspace, stderr_to_stdout: true) do
      {:error, :enoent} -> {:error, :missing_git}
      {:error, reason} -> {:error, {:git_command_failed, args, reason}}
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_command_failed, args, status, output}}
    end
  rescue
    error in ErlangError ->
      case Map.get(error, :original) do
        :enoent -> {:error, :missing_git}
        reason -> {:error, {:git_command_failed, args, reason}}
      end
  end

  defp parse_git_paths(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_git_numstat(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_git_numstat_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_git_numstat_line(line) when is_binary(line) do
    case String.split(line, "\t", parts: 3) do
      [added, deleted, path] ->
        %{
          path: path,
          additions: parse_git_stat_int(added),
          deletions: parse_git_stat_int(deleted)
        }

      _ ->
        nil
    end
  end

  defp parse_git_stat_int("-"), do: 0

  defp parse_git_stat_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_git_stat_int(_), do: 0

  defp classify_pr_risk(changed_paths, numstat) do
    changed_paths = changed_paths || []
    numstat = numstat || []
    total_changes = Enum.reduce(numstat, 0, &(&1.additions + &1.deletions + &2))
    file_count = length(changed_paths)

    cond do
      changed_paths == [] ->
        "low"

      Enum.any?(changed_paths, &high_risk_path?/1) ->
        "high"

      file_count >= 12 or total_changes >= 500 ->
        "high"

      docs_or_test_only_paths?(changed_paths) ->
        "low"

      file_count <= 3 and total_changes <= 120 ->
        "low"

      true ->
        "medium"
    end
  end

  defp docs_or_test_only_paths?(paths) when is_list(paths), do: Enum.all?(paths, &low_risk_path?/1)
  defp docs_or_test_only_paths?(_paths), do: false

  defp low_risk_path?(path) when is_binary(path) do
    base = Path.basename(path)

    String.starts_with?(path, ["docs/", "test/", "elixir/test/", "elixir/test/support/"]) or
      String.ends_with?(path, [".md", ".markdown", ".mdx", ".rst"]) or
      base in ["README", "README.md", "README.markdown", "README.mdx", "CHANGELOG.md"]
  end

  defp low_risk_path?(_path), do: false

  defp high_risk_path?(path) when is_binary(path) do
    String.contains?(path, [
      "/config/",
      "elixir/config/",
      "/priv/repo/migrations/",
      "elixir/priv/repo/migrations/",
      "_web/",
      "security/",
      "auth/",
      "crypto/",
      "billing/",
      "payment/"
    ]) or String.ends_with?(path, "mix.lock")
  end

  defp high_risk_path?(_path), do: false

  defp risk_level_allowed?(risk_level, threshold) do
    risk_level_rank(risk_level) <= risk_level_rank(threshold)
  end

  defp risk_level_rank(level) do
    case normalize_risk_level(level) do
      "low" -> Map.fetch!(@risk_levels, :low)
      "medium" -> Map.fetch!(@risk_levels, :medium)
      "high" -> Map.fetch!(@risk_levels, :high)
      _ -> Map.fetch!(@risk_levels, :medium)
    end
  end

  defp normalize_risk_level(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_risk_level(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_risk_level()
  defp normalize_risk_level(_value), do: "medium"

  defp record_planned_action(nil, _issue, _pr, _decision, _config), do: nil

  defp record_planned_action(%RunLedger{} = ledger, issue, pr, decision, config) do
    risk_assessment = Map.get(decision, :risk_assessment, %{})

    payload = %{
      issue: issue.identifier || issue.id,
      pr: Map.take(pr, [:number, :url, :title, :head_ref_name, :base_ref_name]),
      action: Map.get(decision, :action),
      recovery_kind: Map.get(decision, :recovery_kind),
      wait_interval_seconds: Map.get(decision, :wait_interval_seconds),
      feedback_count: length(Map.get(decision, :feedback_queue, [])),
      feedback_comment_ids: Map.get(decision, :feedback_comment_ids, []),
      conflict_files: Map.get(decision, :conflict_files, []),
      mergeable: Map.get(decision, :mergeable),
      merge_state_status: Map.get(decision, :merge_state_status),
      reply_preview: Map.get(decision, :reply_preview),
      risk_level: Map.get(risk_assessment, :level),
      risk_threshold: Map.get(risk_assessment, :threshold),
      risk_allowed: Map.get(risk_assessment, :allowed),
      review_state: Map.get(config, :review_state),
      rework_state: Map.get(config, :rework_state),
      merge_state: Map.get(config, :merge_state),
      done_state: Map.get(config, :done_state)
    }

    case RunLedger.write_checkpoint(ledger, :release_loop_plan, payload, source: %{loop: "babysit"}) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Release loop plan checkpoint failed issue=#{issue.identifier || issue.id} reason=#{Kernel.inspect(reason)}")
        ledger
    end
  end

  defp record_release_gate_summary(nil, _decision, _summary), do: nil

  defp record_release_gate_summary(%RunLedger{} = ledger, decision, summary) do
    payload = %{
      action: Map.get(decision, :action),
      status: Map.get(summary, :status) || Map.get(summary, "status"),
      results_path: Map.get(summary, :results_path) || Map.get(summary, "results_path")
    }

    case RunLedger.write_checkpoint(ledger, :release_loop_gates_completed, payload, source: %{loop: "babysit"}) do
      {:ok, ledger} ->
        ledger

      {:error, reason} ->
        Logger.warning("Release loop gates checkpoint failed reason=#{Kernel.inspect(reason)}")
        ledger
    end
  end

  defp record_closeout_success(nil, _issue, _pr, _snapshot, _config), do: {:ok, nil}

  defp record_closeout_success(%RunLedger{} = ledger, issue, pr, snapshot, config) do
    payload = %{
      issue: issue.identifier || issue.id,
      pr: Map.take(pr, [:number, :url, :title]),
      review_decision: Map.get(snapshot, :review_decision),
      mergeable: Map.get(snapshot, :mergeable),
      closeout_state: Map.get(config, :merge_state, Config.release_loop_merge_state()),
      done_state: Map.get(config, :done_state, Config.release_loop_done_state())
    }

    case RunLedger.write_checkpoint(ledger, :release_loop_closeout_completed, payload, source: %{loop: "babysit"}) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, reason}
    end
  end

  defp green_to_close?(snapshot) do
    checks = Map.get(snapshot, :checks, %{})

    checks_green?(checks) and approved_review?(snapshot) and not requested_changes?(snapshot)
  end

  defp checks_green?(%{state: state, conclusion: conclusion}) do
    normalized_state = string_value(state) |> String.downcase()
    normalized_conclusion = string_value(conclusion) |> String.downcase()

    normalized_state in ["success", "complete", "completed"] or normalized_conclusion in ["success", "neutral", "skipped"]
  end

  defp checks_green?(_), do: false

  defp checks_pending?(%{state: state}) do
    (string_value(state) |> String.downcase()) in ["pending", "expected", "queued"]
  end

  defp checks_pending?(_), do: false

  defp approved_review?(snapshot) do
    case Map.get(snapshot, :review_decision) do
      decision when is_binary(decision) -> String.downcase(String.trim(decision)) in ["approved", "approval", "ready"]
      _ -> false
    end
  end

  defp mergeable_pending(mergeable, merge_state_status) do
    mergeable_value = string_value(mergeable) |> String.downcase()
    merge_state = string_value(merge_state_status) |> String.downcase()

    mergeable_value in ["unknown", ""] or merge_state in ["dirty", "unknown", "behind"]
  end

  defp requested_changes?(snapshot) do
    snapshot
    |> Map.get(:reviews, [])
    |> Enum.any?(fn review -> string_value(Map.get(review, :state) || Map.get(review, "state")) |> String.downcase() == "changes_requested" end)
  end

  defp feedback_queue(snapshot) do
    reviews = Map.get(snapshot, :reviews, [])
    comments = Map.get(snapshot, :comments, [])
    inline_comments = Map.get(snapshot, :inline_comments, [])

    []
    |> Enum.concat(Enum.map(reviews, &feedback_from_review/1))
    |> Enum.concat(Enum.map(comments, &feedback_from_comment/1))
    |> Enum.concat(Enum.map(inline_comments, &feedback_from_inline_comment/1))
    |> Enum.filter(&(&1 != nil))
  end

  defp conflicting_mergeability?(mergeable, _merge_state_status) do
    (string_value(mergeable) |> String.downcase()) in ["conflicting"]
  end

  defp recovery_kind(snapshot) do
    feedback_queue = feedback_queue(snapshot)
    conflict? = conflicting_mergeability?(Map.get(snapshot, :mergeable), Map.get(snapshot, :merge_state_status))

    cond do
      conflict? and feedback_queue != [] -> :conflict_and_feedback
      conflict? -> :conflict
      requested_changes?(snapshot) -> :review_feedback
      feedback_queue != [] -> :review_feedback
      true -> nil
    end
  end

  defp feedback_comment_ids(snapshot) do
    snapshot
    |> feedback_queue()
    |> Enum.map(&Map.get(&1, :id))
    |> Enum.reject(&is_nil/1)
  end

  defp feedback_from_review(review) do
    state = string_value(Map.get(review, :state) || Map.get(review, "state"))
    body = string_value(Map.get(review, :body) || Map.get(review, "body"))

    cond do
      String.downcase(state) == "changes_requested" ->
        %{kind: "review", summary: body, author: author_login(review), actionable: true, id: string_value(Map.get(review, :id) || Map.get(review, "id"))}

      actionable_text?(body) ->
        %{kind: "review", summary: body, author: author_login(review), actionable: true, id: string_value(Map.get(review, :id) || Map.get(review, "id"))}

      true ->
        nil
    end
  end

  defp feedback_from_comment(comment) do
    body = string_value(Map.get(comment, :body) || Map.get(comment, "body"))
    author = author_login(comment)

    if bot_author?(author) or actionable_text?(body) do
      %{kind: "comment", summary: body, author: author, actionable: true, id: string_value(Map.get(comment, :id) || Map.get(comment, "id"))}
    else
      nil
    end
  end

  defp feedback_from_inline_comment(comment) do
    body = string_value(Map.get(comment, :body) || Map.get(comment, "body"))
    author = author_login(comment)

    %{
      kind: "inline",
      summary: body,
      author: author,
      actionable: true,
      id: string_value(Map.get(comment, :id) || Map.get(comment, "id")),
      path: string_value(Map.get(comment, :path) || Map.get(comment, "path")),
      line: int_value(Map.get(comment, :line) || Map.get(comment, "line"))
    }
    |> drop_nil_values()
  end

  defp build_reply_preview(issue, pr, snapshot) do
    feedback =
      snapshot
      |> feedback_queue()
      |> Enum.take(@review_reply_limit)
      |> Enum.map_join("\n", fn item ->
        line = "- #{Map.get(item, :kind)} by #{Map.get(item, :author, "unknown")}: #{Map.get(item, :summary, "")}"
        String.trim_trailing(line)
      end)

    conflict_note =
      if conflicting_mergeability?(Map.get(snapshot, :mergeable), Map.get(snapshot, :merge_state_status)) do
        conflict_files = Map.get(snapshot, :conflict_files, [])

        conflict_file_note =
          conflict_files
          |> Enum.take(@review_reply_limit)
          |> Enum.map_join("\n", &"- #{&1}")

        "- mergeability conflict detected (#{string_value(Map.get(snapshot, :mergeable)) || "unknown"}/#{string_value(Map.get(snapshot, :merge_state_status)) || "unknown"})\n#{if conflict_file_note == "", do: "- conflict files unavailable", else: conflict_file_note}"
      else
        nil
      end

    header = "Rondo is addressing PR recovery for #{issue.identifier || issue.id} on PR ##{Map.get(pr, :number)}."

    details =
      cond do
        conflict_note && feedback == "" -> conflict_note
        conflict_note -> conflict_note <> "\n" <> feedback
        feedback == "" -> "- no actionable feedback"
        true -> feedback
      end

    "#{header}\n\n#{details}"
  end

  defp actionable_comment(snapshot) do
    snapshot
    |> Map.get(:inline_comments, [])
    |> List.first()
    |> case do
      nil -> Map.get(snapshot, :comments, []) |> List.first()
      comment -> comment
    end
  end

  defp actionable_text?(text) when is_binary(text) do
    Regex.match?(~r/\b(fix|change|address|rework|please|requested|should)\b/i, text)
  end

  defp actionable_text?(_text), do: false

  defp bot_author?(author) when is_binary(author), do: String.contains?(String.downcase(author), "bot")
  defp bot_author?(_author), do: false

  defp author_login(map) when is_map(map) do
    case first_present(map, [:author, "author"]) do
      %{login: login} -> string_value(login)
      %{"login" => login} -> string_value(login)
      login when is_binary(login) -> login
      _ -> nil
    end
  end

  defp review_env(repo, pr, opts) do
    %{
      "RONDO_PR_REPO" => string_value(repo),
      "RONDO_PR_NUMBER" => to_string(Map.get(pr, :number)),
      "RONDO_PR_URL" => string_value(Map.get(pr, :url)),
      "RONDO_PR_BRANCH" => string_value(Map.get(pr, :head_ref_name)),
      "RONDO_PR_TITLE" => string_value(Map.get(pr, :title)),
      "RONDO_PR_STATE" => string_value(Map.get(pr, :state)),
      "RONDO_RELEASE_LOOP_WAIT_SECONDS" => release_loop_wait_seconds(opts)
    }
  end

  defp run_shell_command(command, env, runner) do
    env_list = Enum.map(env, fn {key, value} -> {key, value} end)

    case runner.("sh", ["-lc", command], stderr_to_stdout: true, env: env_list) do
      {:error, :enoent} -> {:error, :missing_shell}
      {:error, reason} -> {:error, {:shell_error, reason}}
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:shell_failed, status, output}}
    end
  rescue
    error in ErlangError ->
      case Map.get(error, :original) do
        :enoent -> {:error, :missing_shell}
        reason -> {:error, {:shell_error, reason}}
      end
  end

  defp release_loop_wait_seconds(opts) do
    opts
    |> Keyword.get(:release_loop)
    |> Kernel.||(Config.release_loop())
    |> Kernel.||(%{})
    |> Map.get(:wait_interval_seconds, Config.release_loop_wait_interval_seconds())
    |> to_string()
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp int_value(_), do: nil

  defp boolean_value(value) when is_boolean(value), do: value
  defp boolean_value(_), do: nil

  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: String.trim(value)
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value), do: to_string(value)

  defp plan_action_kind(snapshot) do
    cond do
      recovery_kind(snapshot) != nil ->
        :fix

      checks_pending?(Map.get(snapshot, :checks, %{})) or
          mergeable_pending(Map.get(snapshot, :mergeable), Map.get(snapshot, :merge_state_status)) ->
        :wait

      green_to_close?(snapshot) ->
        :merge

      true ->
        :wait
    end
  end
end
