defmodule Rondo.ReplayCorpusTest do
  @moduledoc """
  Replays the committed recorded-run corpus (`test/fixtures/recorded_runs/<case>/`)
  through each provider's StreamParser and asserts the normalized event
  sequence is stable, plus a handful of cross-adapter invariants that the
  parser layer is expected to hold regardless of provider.

  Each case directory contains:

    * `case.json` - metadata (`adapter`, `archetype`, `synthetic`, `source`).
    * `raw_stream.jsonl` - the RAW pre-parse provider stream, one JSON object
      per line, redacted before being committed.
    * `expected.json` - the golden normalized event sequence.

  ## Regenerating the golden files

  `expected.json` files are golden fixtures, not scratch output. Regenerating
  them requires an explicit opt-in:

      REGEN_REPLAY_GOLDEN=1 mix test test/rondo/replay_corpus_test.exs

  Setting the flag overwrites every case's `expected.json` with the parser's
  current output and then intentionally FAILS the test that touched it, so a
  green `mix test` run can never happen silently under regen mode. After
  regenerating, unset the flag, run `git diff` on the fixture files, and have
  a human review every changed line before committing - a regen diff IS a
  finding about parser behavior, never something to rubber-stamp.

  ## Known drift

  RON-136 closed the R2 drift documented here previously:
  `Rondo.Claude.StreamParser.extract_usage/1` now surfaces
  `cache_read_tokens` / `cache_write_tokens` / `cost` at parity with the
  Codex and Pi parsers. The cross-adapter invariant tests below assert that
  parity for all three adapters; there is no remaining known-drift exclusion
  in this suite.
  """

  use ExUnit.Case, async: true

  alias Rondo.Claude.StreamParser, as: ClaudeStreamParser
  alias Rondo.Codex.StreamParser, as: CodexStreamParser
  alias Rondo.Pi.StreamParser, as: PiStreamParser

  @fixtures_root Path.expand("../fixtures/recorded_runs", __DIR__)
  @regen? System.get_env("REGEN_REPLAY_GOLDEN") == "1"

  @parsers %{
    "claude_code" => ClaudeStreamParser,
    "codex" => CodexStreamParser,
    "pi" => PiStreamParser
  }

  @case_names @fixtures_root
              |> File.ls!()
              |> Enum.filter(&File.dir?(Path.join(@fixtures_root, &1)))
              |> Enum.sort()

  for case_name <- @case_names do
    test "replays #{case_name} to the golden normalized event sequence" do
      Rondo.ReplayCorpusTest.assert_case_replay!(unquote(case_name))
    end
  end

  describe "cross-adapter invariants" do
    test "codex and pi usage events carry cache-token and cost fields (R2 invariant)" do
      for {case_name, adapter} <- [{"codex_gate_fail", "codex"}, {"pi_invalid_final_report", "pi"}] do
        usages = usage_events(case_name)

        assert usages != [], "expected at least one usage-bearing event in #{case_name}"

        for usage <- usages do
          assert Map.has_key?(usage, :cache_read_tokens),
                 "#{adapter} (#{case_name}) usage is missing cache_read_tokens: #{inspect(usage)}"

          assert Map.has_key?(usage, :cache_write_tokens),
                 "#{adapter} (#{case_name}) usage is missing cache_write_tokens: #{inspect(usage)}"

          assert Map.has_key?(usage, :cost),
                 "#{adapter} (#{case_name}) usage is missing cost: #{inspect(usage)}"
        end
      end
    end

    test "claude_code usage events carry cache-token and cost fields at parity (R2 fixed by RON-136)" do
      # This test used to pin a documented known-drift exclusion (tagged
      # :known_drift, tracked by RON-141): Rondo.Claude.StreamParser
      # .extract_usage/1 only returned input_tokens/output_tokens/
      # total_tokens, even though the raw Claude usage payload carries
      # cache_creation_input_tokens and cache_read_input_tokens (see the
      # allowlist in Rondo.RunLedger.secret_key?/1 and content_key?/1, which
      # explicitly protects those two keys from redaction). RON-136 ported
      # the Codex/Pi cache-token + cost normalization into the Claude parser,
      # closing the drift, so this now asserts parity instead of pinning the
      # gap.
      usages = usage_events("claude_code_clean_success")

      assert usages != [], "expected at least one usage-bearing event in claude_code_clean_success"

      for usage <- usages do
        assert Map.has_key?(usage, :cache_read_tokens),
               "claude_code usage is missing cache_read_tokens: #{inspect(usage)}"

        assert Map.has_key?(usage, :cache_write_tokens),
               "claude_code usage is missing cache_write_tokens: #{inspect(usage)}"

        assert Map.has_key?(usage, :cost),
               "claude_code usage is missing cost: #{inspect(usage)}"
      end
    end

    test "terminal event is the last line and carries everything needed to flush final output (R1 invariant, parser-layer slice)" do
      # Full process-exit flush guarantees (PTY buffering for Claude's
      # Node-based CLI, port line discipline for Codex/Pi) live below the
      # parser, in Rondo.Claude.CLI / Rondo.Codex.CLI / Rondo.Pi.CLI, and are
      # covered by those modules' own tests (see the script(1) PTY wrapper
      # comment in claude/cli.ex). What the parser layer CAN express is
      # narrower: the terminal event must be the last raw line, and any
      # final-report text an adapter would surface must be fully derivable
      # from events up to and including that line - nothing after it should
      # be required.
      cases = [
        {"claude_code_clean_success", "claude_code", :result, true},
        {"claude_code_session_resume", "claude_code", :result, true},
        {"codex_gate_fail", "codex", :invocation_failed, true},
        {"pi_invalid_final_report", "pi", :invocation_completed, false}
      ]

      for {case_name, adapter, terminal_type, expect_final_text?} <- cases do
        {parser, raw_lines, _expected_path} = load_case(case_name)
        events = Enum.map(raw_lines, fn line -> ok_event!(parser, line) end)
        last_event = List.last(events)

        assert last_event.event_type == terminal_type,
               "#{case_name}: expected terminal event #{inspect(terminal_type)}, got #{inspect(last_event.event_type)}"

        final_text = final_report_text(adapter, events)

        if expect_final_text? do
          assert is_binary(final_text) and final_text != "",
                 "#{case_name}: expected a non-blank final report derivable from the flushed stream"
        else
          assert is_nil(final_text),
                 "#{case_name}: expected no derivable final report - this case models a run whose terminal output was not usable"
        end
      end
    end
  end

  # -- Shared helpers (used both by the generated per-case tests above and
  #    the cross-adapter invariant tests) ------------------------------------

  def assert_case_replay!(case_name) do
    {parser, raw_lines, expected_path} = load_case(case_name)
    actual = Enum.map(raw_lines, fn line -> parser |> ok_event!(line) |> canonicalize() end)

    if @regen? do
      File.write!(expected_path, Jason.encode!(actual, pretty: true) <> "\n")

      flunk("""
      REGEN_REPLAY_GOLDEN=1 was set: regenerated #{Path.relative_to_cwd(expected_path)}.

      expected.json is a golden file. Review the diff with `git diff` and confirm
      the change is an intentional, understood parser behavior change - never
      auto-accept it. Then rerun `mix test` WITHOUT REGEN_REPLAY_GOLDEN=1 to
      confirm the suite is green against the new golden.
      """)
    else
      expected = expected_path |> File.read!() |> Jason.decode!()

      assert actual == expected, """
      #{case_name}: normalized event sequence drifted from expected.json.

      If this is an intentional parser behavior change, regenerate with:
        REGEN_REPLAY_GOLDEN=1 mix test test/rondo/replay_corpus_test.exs
      then review the diff before committing.
      """
    end
  end

  defp load_case(case_name) do
    dir = Path.join(@fixtures_root, case_name)
    case_meta = dir |> Path.join("case.json") |> File.read!() |> Jason.decode!()
    adapter = Map.fetch!(case_meta, "adapter")
    parser = Map.fetch!(@parsers, adapter)

    raw_lines =
      dir
      |> Path.join("raw_stream.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)

    {parser, raw_lines, Path.join(dir, "expected.json")}
  end

  defp ok_event!(parser, line) do
    case parser.parse_line(line) do
      {:ok, event} -> event
      {:error, reason} -> flunk("fixture line failed to parse: #{inspect(reason)}\nline: #{line}")
    end
  end

  defp canonicalize(event), do: event |> Jason.encode!() |> Jason.decode!()

  defp usage_events(case_name) do
    {parser, raw_lines, _expected_path} = load_case(case_name)

    raw_lines
    |> Enum.map(fn line -> ok_event!(parser, line) end)
    |> Enum.map(fn event -> parser.extract_usage(event) end)
    |> Enum.reject(&is_nil/1)
  end

  defp final_report_text("claude_code", events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      blank_to_nil(Map.get(event, "result") || Map.get(event, :result))
    end)
  end

  defp final_report_text("codex", events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event -> CodexStreamParser.assistant_text(event) end)
  end

  defp final_report_text("pi", events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      PiStreamParser.explicit_result(event) || PiStreamParser.assistant_text(event)
    end)
  end

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_text), do: nil
end
