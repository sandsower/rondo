defmodule RondoWeb.ArchivedRunsTest do
  use Rondo.TestSupport

  alias RondoWeb.ArchivedRuns

  test "default filters and normalization handle mixed key styles and invalid values" do
    assert ArchivedRuns.default_filters() == %{
             search: "",
             status: "all",
             model: "all",
             project: "all",
             date_from: "",
             date_to: "",
             sort_by: "ended",
             sort_dir: "desc",
             page: 1,
             page_size: 25
           }

    assert ArchivedRuns.merge_filters(%{}, %{"search" => "  alpha  ", "page-size" => "3"}) == %{
             search: "alpha",
             status: "all",
             model: "all",
             project: "all",
             date_from: "",
             date_to: "",
             sort_by: "ended",
             sort_dir: "desc",
             page: 1,
             page_size: 3
           }

    assert ArchivedRuns.merge_filters(%{}, %{search: "  beta  ", page_size: 4}) == %{
             search: "beta",
             status: "all",
             model: "all",
             project: "all",
             date_from: "",
             date_to: "",
             sort_by: "ended",
             sort_dir: "desc",
             page: 1,
             page_size: 4
           }

    assert ArchivedRuns.normalize_filters(%{
             search: [:not_binary],
             status: "",
             model: :codex,
             project: nil,
             date_from: nil,
             date_to: "",
             sort_by: :bogus,
             sort_dir: :sideways,
             page: "0",
             page_size: "101"
           }) == %{
             search: "",
             status: "all",
             model: "all",
             project: "all",
             date_from: "",
             date_to: "",
             sort_by: "ended",
             sort_dir: "desc",
             page: 1,
             page_size: 100
           }

    assert ArchivedRuns.merge_filters(%{}, %{1 => "  alpha  "}) == %{
             search: "",
             status: "all",
             model: "all",
             project: "all",
             date_from: "",
             date_to: "",
             sort_by: "ended",
             sort_dir: "desc",
             page: 1,
             page_size: 25
           }

    assert ArchivedRuns.normalize_filters(%{
             page: 1.5,
             page_size: 2.5
           }) == %{
             search: "",
             status: "all",
             model: "all",
             project: "all",
             date_from: "",
             date_to: "",
             sort_by: "ended",
             sort_dir: "desc",
             page: 1,
             page_size: 25
           }
  end

  test "view filters, sorts, paginates, and derives options across archive rows" do
    rows = archived_rows_fixture()

    default_view = ArchivedRuns.view(rows, %{})
    assert default_view.rows == rows
    assert default_view.total == length(rows)
    assert default_view.page == 1
    assert default_view.page_count == 1
    assert default_view.recent_failures |> Enum.map(& &1.issue_identifier) == ["MT-FAIL", "MT-EXIT", "MT-ERR"]
    assert default_view.options.statuses == ["completed", "error", "exited", "failed", "handed_off", "terminated", "unknown"]
    assert default_view.options.models == ["codex", "openrouter/anthropic/claude-sonnet-4", "pi", "sonnet", "unknown"]
    assert default_view.options.projects == ["alpha", "beta", "delta", "gamma", "repo-b", "unknown"]

    search_view = ArchivedRuns.view(rows, %{search: "handed"})
    assert [%{issue_identifier: "MT-HAND"}] = search_view.rows

    status_view = ArchivedRuns.view(rows, %{status: "failed", sort_by: "issue", sort_dir: "asc"})
    assert status_view.total == 3
    assert Enum.map(status_view.rows, & &1.issue_identifier) == ["MT-ERR", "MT-EXIT", "MT-FAIL"]

    completed_status_view = ArchivedRuns.view(rows, %{status: "completed", sort_by: "issue", sort_dir: "asc"})
    assert Enum.map(completed_status_view.rows, & &1.issue_identifier) == ["MT-DONE"]

    project_view = ArchivedRuns.view(rows, %{project: "unknown", sort_by: "issue", sort_dir: "asc"})
    assert [%{issue_identifier: "MT-UNKNOWN"}] = project_view.rows

    model_view = ArchivedRuns.view(rows, %{model: "codex", sort_by: "issue", sort_dir: "asc"})
    assert Enum.map(model_view.rows, & &1.issue_identifier) == ["MT-EXIT"]

    date_window_view = ArchivedRuns.view(rows, %{date_from: "2026-06-26", date_to: "2026-06-29", sort_by: "issue", sort_dir: "asc"})
    assert Enum.map(date_window_view.rows, & &1.issue_identifier) == ["MT-ERR", "MT-EXIT", "MT-FAIL", "MT-TERM"]

    invalid_date_view = ArchivedRuns.view(rows, %{date_from: "bad-date", date_to: "also-bad", sort_by: "issue", sort_dir: "asc"})
    assert invalid_date_view.total == 5

    page_view = ArchivedRuns.view(rows, %{sort_by: "issue", sort_dir: "asc", page_size: 2, page: 2})
    assert page_view.total == length(rows)
    assert page_view.page == 2
    assert page_view.page_count == 4
    assert Enum.map(page_view.rows, & &1.issue_identifier) == ["MT-EXIT", "MT-FAIL"]

    clamped_view = ArchivedRuns.view(rows, %{sort_by: "issue", sort_dir: "asc", page_size: 2, page: 99})
    assert clamped_view.page == 4
    assert Enum.map(clamped_view.rows, & &1.issue_identifier) == ["MT-UNKNOWN"]

    started_view = ArchivedRuns.view(rows, %{sort_by: "started", sort_dir: "asc"})
    assert Enum.map(started_view.rows, & &1.issue_identifier) == ["MT-HAND", "MT-UNKNOWN", "MT-DONE", "MT-TERM", "MT-ERR", "MT-EXIT", "MT-FAIL"]

    ended_view = ArchivedRuns.view(rows, %{sort_by: "ended", sort_dir: "asc"})
    assert Enum.map(ended_view.rows, & &1.issue_identifier) == ["MT-HAND", "MT-UNKNOWN", "MT-DONE", "MT-TERM", "MT-ERR", "MT-EXIT", "MT-FAIL"]

    duration_view = ArchivedRuns.view(rows, %{sort_by: "duration", sort_dir: "desc"})
    assert Enum.map(duration_view.rows, & &1.issue_identifier) == ["MT-TERM", "MT-ERR", "MT-FAIL", "MT-DONE", "MT-EXIT", "MT-HAND", "MT-UNKNOWN"]

    tokens_view = ArchivedRuns.view(rows, %{sort_by: "tokens", sort_dir: "desc"})
    assert Enum.map(tokens_view.rows, & &1.issue_identifier) == ["MT-HAND", "MT-TERM", "MT-ERR", "MT-EXIT", "MT-FAIL", "MT-DONE", "MT-UNKNOWN"]

    cost_view = ArchivedRuns.view(rows, %{sort_by: "cost", sort_dir: "desc"})
    assert Enum.map(cost_view.rows, & &1.issue_identifier) == ["MT-HAND", "MT-ERR", "MT-FAIL", "MT-DONE", "MT-EXIT", "MT-TERM", "MT-UNKNOWN"]

    result_view = ArchivedRuns.view(rows, %{sort_by: "result", sort_dir: "asc"})
    assert Enum.map(result_view.rows, & &1.issue_identifier) == ["MT-UNKNOWN", "MT-DONE", "MT-ERR", "MT-FAIL", "MT-HAND", "MT-EXIT", "MT-TERM"]

    model_sort_view = ArchivedRuns.view(rows, %{sort_by: "model", sort_dir: "asc"})
    assert Enum.map(model_sort_view.rows, & &1.issue_identifier) == ["MT-EXIT", "MT-HAND", "MT-ERR", "MT-FAIL", "MT-DONE", "MT-TERM", "MT-UNKNOWN"]

    project_sort_view = ArchivedRuns.view(rows, %{sort_by: "project", sort_dir: "asc"})
    assert Enum.map(project_sort_view.rows, & &1.issue_identifier) == ["MT-FAIL", "MT-DONE", "MT-ERR", "MT-HAND", "MT-TERM", "MT-EXIT", "MT-UNKNOWN"]

    status_sort_view = ArchivedRuns.view(rows, %{sort_by: "status", sort_dir: "asc"})
    assert Enum.map(status_sort_view.rows, & &1.issue_identifier) == ["MT-FAIL", "MT-EXIT", "MT-TERM", "MT-HAND", "MT-UNKNOWN", "MT-DONE", "MT-ERR"]

    issue_sort_view = ArchivedRuns.view(rows, %{sort_by: "issue", sort_dir: "asc"})
    assert Enum.map(issue_sort_view.rows, & &1.issue_identifier) == ["MT-DONE", "MT-ERR", "MT-EXIT", "MT-FAIL", "MT-HAND", "MT-TERM", "MT-UNKNOWN"]
  end

  test "empty views retain one empty pagination page" do
    view = ArchivedRuns.view([], %{})

    assert view.rows == []
    assert view.total == 0
    assert view.page_count == 1
  end

  test "next_sort and sorter comparison handle toggles, invalid fields, equality, and nils" do
    default = ArchivedRuns.default_filters()
    started_asc = ArchivedRuns.next_sort(default, "started")
    assert started_asc.sort_by == "started"
    assert started_asc.sort_dir == "asc"
    assert started_asc.page == 1

    started_desc = ArchivedRuns.next_sort(started_asc, "started")
    assert started_desc.sort_by == "started"
    assert started_desc.sort_dir == "desc"

    assert ArchivedRuns.next_sort(default, "bogus") == default

    assert ArchivedRuns.Sorter.compare(nil, 1) == :lt
    assert ArchivedRuns.Sorter.compare(1, nil) == :gt
    assert ArchivedRuns.Sorter.compare(1, 1) == :eq
    assert ArchivedRuns.Sorter.compare(1, 2) == :lt
    assert ArchivedRuns.Sorter.compare(2, 1) == :gt
  end

  defp archived_rows_fixture do
    [
      %{
        issue_identifier: "MT-FAIL",
        issue_title: "Failure",
        project: "alpha",
        repo: "repo-a",
        status: "failed",
        outcome: "exited: boom",
        started_at: ~U[2026-06-29 09:00:00Z],
        finished_at: ~U[2026-06-29 09:05:00Z],
        model: "sonnet",
        provider: "openrouter",
        duration_ms: 300_000,
        tokens: %{total_tokens: 10},
        cost: 0.1,
        last_meaningful_result: "gates fail"
      },
      %{
        issue_identifier: "MT-EXIT",
        issue_title: "Exited",
        project: nil,
        repo: "repo-b",
        status: "exited",
        outcome: "exited: timeout",
        started_at: "2026-06-28T09:00:00Z",
        finished_at: nil,
        duration_ms: 60_000,
        adapter: "codex",
        tokens: %{total_tokens: 20},
        last_meaningful_result: "retry later"
      },
      %{
        issue_identifier: "MT-ERR",
        issue_title: "Error",
        project: "beta",
        repo: nil,
        status: "error",
        outcome: "error",
        started_at: ~U[2026-06-27 09:00:00Z],
        finished_at: ~U[2026-06-27 09:10:00Z],
        duration_ms: 600_000,
        adapter: "pi",
        tokens: %{total_tokens: 30},
        cost: 0.2
      },
      %{
        issue_identifier: "MT-TERM",
        issue_title: "Terminated",
        project: "gamma",
        repo: nil,
        status: "terminated",
        outcome: "terminated",
        started_at: ~U[2026-06-26 09:00:00Z],
        finished_at: ~U[2026-06-26 09:30:00Z],
        duration_ms: 1_800_000,
        tokens: %{total_tokens: 40}
      },
      %{
        issue_identifier: "MT-HAND",
        issue_title: "Handed off",
        project: "delta",
        repo: "repo-d",
        status: "handed_off",
        outcome: "handed_off",
        started_at: "invalid",
        finished_at: "invalid",
        model: "openrouter/anthropic/claude-sonnet-4",
        duration_ms: 5_000,
        tokens: %{total_tokens: 50},
        cost: 0.3
      },
      %{
        issue_identifier: "MT-DONE",
        issue_title: "Completed",
        project: "alpha",
        repo: "repo-a",
        status: "completed",
        outcome: "completed",
        started_at: ~U[2026-06-25 09:00:00Z],
        finished_at: ~U[2026-06-25 09:10:00Z],
        duration_ms: 120_000,
        model: "sonnet",
        tokens: %{total_tokens: 5},
        cost: 0.05,
        last_meaningful_result: "completed"
      },
      %{
        issue_identifier: "MT-UNKNOWN",
        issue_title: nil,
        project: nil,
        repo: nil,
        status: nil,
        outcome: nil,
        started_at: nil,
        finished_at: nil,
        adapter: nil,
        tokens: nil,
        cost: nil,
        last_meaningful_result: nil
      }
    ]
  end
end
