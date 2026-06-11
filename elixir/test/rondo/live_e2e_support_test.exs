defmodule Rondo.LiveE2ESupportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Rondo.LiveE2E

  defp env(map), do: fn key -> Map.get(map, key) end

  defp full_env(overrides \\ %{}) do
    Map.merge(
      %{
        "RONDO_RUN_LIVE_E2E" => "1",
        "LINEAR_API_KEY" => "lin_api_real",
        "RONDO_E2E_LINEAR_TEAM" => "RONT",
        "RONDO_E2E_LINEAR_PROJECT" => "Rondo E2E"
      },
      overrides
    )
  end

  describe "gating" do
    test "enabled?/1 requires RONDO_RUN_LIVE_E2E=1" do
      assert LiveE2E.enabled?(env(%{"RONDO_RUN_LIVE_E2E" => "1"}))
      refute LiveE2E.enabled?(env(%{"RONDO_RUN_LIVE_E2E" => "true"}))
      refute LiveE2E.enabled?(env(%{}))
    end

    test "skip_reason/0 names the gate variable and required configuration" do
      reason = LiveE2E.skip_reason()

      assert reason =~ "RONDO_RUN_LIVE_E2E=1"
      assert reason =~ "LINEAR_API_KEY"
      assert reason =~ "RONDO_E2E_LINEAR_TEAM"
      assert reason =~ "RONDO_E2E_LINEAR_PROJECT"
    end
  end

  # Injects a find_executable stub that resolves known executables to fixed paths.
  defp find_executable_found(name) do
    case name do
      "beislid" -> "/usr/local/bin/beislid"
      "claude" -> "/usr/local/bin/claude"
      "pi" -> "/usr/local/bin/pi"
      _ -> nil
    end
  end

  defp find_executable_missing(_name), do: nil

  describe "load_context/2" do
    test "lists every missing required variable" do
      assert {:error, {:missing_env, missing}} =
               LiveE2E.load_context(env(%{"LINEAR_API_KEY" => " "}), &find_executable_found/1)

      assert missing == ["LINEAR_API_KEY", "RONDO_E2E_LINEAR_TEAM", "RONDO_E2E_LINEAR_PROJECT"]
    end

    test "rejects the unit-test placeholder Linear key" do
      assert {:error, :placeholder_linear_api_key} =
               LiveE2E.load_context(
                 env(full_env(%{"LINEAR_API_KEY" => "test-linear-api-key"})),
                 &find_executable_found/1
               )
    end

    test "probes for beislid when no override is set; uses it when present" do
      assert {:ok, context} =
               LiveE2E.load_context(env(full_env()), &find_executable_found/1)

      assert context.action_policy_command == "/usr/local/bin/beislid"
      assert context.action_policy_policy_file =~ "fixtures/e2e_action_policy.json"
      assert File.regular?(context.action_policy_policy_file)
    end

    test "fails with a clear message when beislid is absent and no override is set" do
      assert {:error, {:action_policy_command_missing, override_var}} =
               LiveE2E.load_context(env(full_env()), &find_executable_missing/1)

      assert override_var == LiveE2E.action_policy_override_var()
      assert override_var == "RONDO_E2E_ACTION_POLICY_COMMAND"
    end

    test "explicit RONDO_E2E_ACTION_POLICY_COMMAND=fake opts in to the allow-all stub" do
      override = %{"RONDO_E2E_ACTION_POLICY_COMMAND" => LiveE2E.action_policy_fake_value()}

      # find_executable_found resolves "claude" so the agent CLI probe passes;
      # this test is about action-policy, not agent command selection.
      assert {:ok, context} =
               LiveE2E.load_context(env(full_env(override)), &find_executable_found/1)

      assert context.action_policy_command == :fake
      assert context.action_policy_policy_file == nil
    end

    test "explicit non-fake RONDO_E2E_ACTION_POLICY_COMMAND uses that path directly" do
      override = %{"RONDO_E2E_ACTION_POLICY_COMMAND" => "/opt/bin/beislid"}

      # find_executable_found resolves "claude" so the agent CLI probe passes;
      # this test is about action-policy, not agent command selection.
      assert {:ok, context} =
               LiveE2E.load_context(env(full_env(override)), &find_executable_found/1)

      assert context.action_policy_command == "/opt/bin/beislid"
      assert context.action_policy_policy_file =~ "fixtures/e2e_action_policy.json"
    end

    test "returns context with correct defaults for other fields" do
      assert {:ok, context} = LiveE2E.load_context(env(full_env()), &find_executable_found/1)

      assert context.team_key == "RONT"
      assert context.project_name == "Rondo E2E"
      assert context.agent_adapter == "claude_code"
      assert context.agent_command == "claude"
      assert context.agent_max_turns == 10
    end

    test "honors optional overrides and falls back on invalid max turns" do
      overrides = %{
        "RONDO_E2E_CLAUDE_COMMAND" => "/usr/local/bin/claude",
        "RONDO_E2E_CLAUDE_MAX_TURNS" => "5",
        "RONDO_E2E_ACTION_POLICY_COMMAND" => "/opt/bin/beislid"
      }

      assert {:ok, context} =
               LiveE2E.load_context(env(full_env(overrides)), &find_executable_missing/1)

      assert context.agent_command == "/usr/local/bin/claude"
      assert context.agent_max_turns == 5
      assert context.action_policy_command == "/opt/bin/beislid"

      assert {:ok, context} =
               LiveE2E.load_context(
                 env(full_env(%{"RONDO_E2E_CLAUDE_MAX_TURNS" => "zero"})),
                 &find_executable_found/1
               )

      assert context.agent_max_turns == 10
    end
  end

  describe "adapter selection" do
    test "defaults to claude_code when RONDO_E2E_AGENT_ADAPTER is not set" do
      assert {:ok, context} = LiveE2E.load_context(env(full_env()), &find_executable_found/1)
      assert context.agent_adapter == "claude_code"
    end

    test "selects pi adapter when RONDO_E2E_AGENT_ADAPTER=pi" do
      overrides = %{"RONDO_E2E_AGENT_ADAPTER" => "pi"}

      assert {:ok, context} =
               LiveE2E.load_context(
                 env(full_env(overrides)),
                 fn
                   "pi" -> "/usr/local/bin/pi"
                   "beislid" -> "/usr/local/bin/beislid"
                   _ -> nil
                 end
               )

      assert context.agent_adapter == "pi"
      assert context.agent_command == "pi"
    end

    test "returns config error for unknown adapter value" do
      overrides = %{"RONDO_E2E_AGENT_ADAPTER" => "openai"}

      assert {:error, {:invalid_agent_adapter, "openai", accepted}} =
               LiveE2E.load_context(env(full_env(overrides)), &find_executable_found/1)

      assert "claude_code" in accepted
      assert "pi" in accepted
    end

    test "probe-honest failure when claude CLI is not on PATH (claude_code adapter)" do
      # Use action-policy fake opt-in so we isolate the agent CLI probe failure.
      overrides = %{
        "RONDO_E2E_ACTION_POLICY_COMMAND" => LiveE2E.action_policy_fake_value()
      }

      assert {:error, {:agent_cli_missing, command, env_var}} =
               LiveE2E.load_context(env(full_env(overrides)), &find_executable_missing/1)

      assert command == "claude"
      assert env_var == "RONDO_E2E_AGENT_COMMAND"
    end

    test "probe-honest failure when pi CLI is not on PATH" do
      # Use action-policy fake opt-in so we isolate the agent CLI probe failure.
      overrides = %{
        "RONDO_E2E_AGENT_ADAPTER" => "pi",
        "RONDO_E2E_ACTION_POLICY_COMMAND" => LiveE2E.action_policy_fake_value()
      }

      assert {:error, {:agent_cli_missing, command, env_var}} =
               LiveE2E.load_context(env(full_env(overrides)), &find_executable_missing/1)

      assert is_binary(command)
      assert is_binary(env_var)
      # The message should name the missing command and the env var to set
      assert String.length(command) > 0
      assert String.length(env_var) > 0
    end

    test "pi adapter with explicit RONDO_E2E_AGENT_COMMAND" do
      overrides = %{
        "RONDO_E2E_AGENT_ADAPTER" => "pi",
        "RONDO_E2E_AGENT_COMMAND" => "/opt/bin/pi"
      }

      # Explicit command path — trusted without probing; only beislid needs to be found
      assert {:ok, context} =
               LiveE2E.load_context(
                 env(full_env(overrides)),
                 &find_executable_found/1
               )

      assert context.agent_adapter == "pi"
      assert context.agent_command == "/opt/bin/pi"
    end
  end

  describe "generalized env vars and deprecated aliases" do
    test "RONDO_E2E_AGENT_COMMAND takes precedence over RONDO_E2E_CLAUDE_COMMAND" do
      overrides = %{
        "RONDO_E2E_AGENT_COMMAND" => "/opt/bin/claude",
        "RONDO_E2E_CLAUDE_COMMAND" => "/usr/local/bin/claude"
      }

      assert {:ok, context} =
               LiveE2E.load_context(env(full_env(overrides)), &find_executable_found/1)

      assert context.agent_command == "/opt/bin/claude"
    end

    test "RONDO_E2E_AGENT_MAX_TURNS takes precedence over RONDO_E2E_CLAUDE_MAX_TURNS" do
      overrides = %{
        "RONDO_E2E_AGENT_MAX_TURNS" => "7",
        "RONDO_E2E_CLAUDE_MAX_TURNS" => "3"
      }

      assert {:ok, context} =
               LiveE2E.load_context(env(full_env(overrides)), &find_executable_found/1)

      assert context.agent_max_turns == 7
    end

    test "RONDO_E2E_CLAUDE_COMMAND still works as deprecated alias and logs a warning" do
      overrides = %{"RONDO_E2E_CLAUDE_COMMAND" => "/usr/local/bin/claude-beta"}

      log =
        capture_log(fn ->
          assert {:ok, context} =
                   LiveE2E.load_context(env(full_env(overrides)), &find_executable_found/1)

          assert context.agent_command == "/usr/local/bin/claude-beta"
        end)

      assert log =~ "RONDO_E2E_CLAUDE_COMMAND is deprecated"
      assert log =~ "RONDO_E2E_AGENT_COMMAND"
    end

    test "RONDO_E2E_CLAUDE_MAX_TURNS still works as deprecated alias and logs a warning" do
      overrides = %{"RONDO_E2E_CLAUDE_MAX_TURNS" => "15"}

      log =
        capture_log(fn ->
          assert {:ok, context} =
                   LiveE2E.load_context(env(full_env(overrides)), &find_executable_found/1)

          assert context.agent_max_turns == 15
        end)

      assert log =~ "RONDO_E2E_CLAUDE_MAX_TURNS is deprecated"
      assert log =~ "RONDO_E2E_AGENT_MAX_TURNS"
    end

    test "blank RONDO_E2E_AGENT_COMMAND falls through to probe instead of returning an empty path" do
      # Setting the var to "" or whitespace-only must not produce {:ok, ""}; it must
      # fall through to the probe path (and fail when the binary is missing).
      for blank <- ["", "   "] do
        overrides = %{
          "RONDO_E2E_AGENT_COMMAND" => blank,
          "RONDO_E2E_ACTION_POLICY_COMMAND" => LiveE2E.action_policy_fake_value()
        }

        assert {:error, {:agent_cli_missing, _command, _env_var}} =
                 LiveE2E.load_context(env(full_env(overrides)), &find_executable_missing/1),
               "expected probe failure for blank value #{inspect(blank)}, got ok"
      end
    end

    test "blank RONDO_E2E_CLAUDE_COMMAND (deprecated alias) also falls through to probe" do
      overrides = %{
        "RONDO_E2E_CLAUDE_COMMAND" => "",
        "RONDO_E2E_ACTION_POLICY_COMMAND" => LiveE2E.action_policy_fake_value()
      }

      assert {:error, {:agent_cli_missing, _command, _env_var}} =
               LiveE2E.load_context(env(full_env(overrides)), &find_executable_missing/1)
    end
  end

  describe "workflow_overrides_for_adapter/1" do
    test "emits claude: section for claude_code adapter" do
      context = %{
        agent_adapter: "claude_code",
        agent_command: "claude",
        agent_max_turns: 10
      }

      content = LiveE2E.workflow_overrides_for_adapter(context)

      assert Keyword.get(content, :agent_adapter) == "claude_code"
      assert Keyword.get(content, :agent_max_turns) == 10
      assert Keyword.get(content, :claude_command) == "claude"
      assert Keyword.get(content, :claude_max_turns) == 10
      refute Keyword.has_key?(content, :pi_command)
    end

    test "emits pi: section for pi adapter" do
      context = %{
        agent_adapter: "pi",
        agent_command: "/opt/bin/pi",
        agent_max_turns: 5
      }

      content = LiveE2E.workflow_overrides_for_adapter(context)

      assert Keyword.get(content, :agent_adapter) == "pi"
      assert Keyword.get(content, :agent_max_turns) == 5
      assert Keyword.get(content, :pi_command) == "/opt/bin/pi"
      assert Keyword.get(content, :pi_turn_timeout_ms) == 3_600_000
      assert Keyword.get(content, :pi_stall_timeout_ms) == 300_000
      refute Keyword.has_key?(content, :claude_command)
    end
  end

  defp team_payload(states) do
    %{
      "data" => %{
        "teams" => %{
          "nodes" => [
            %{
              "id" => "team-uuid",
              "key" => "RONT",
              "name" => "Rondo Test",
              "states" => %{"nodes" => states}
            }
          ]
        }
      }
    }
  end

  defp create_context do
    %{
      team: %{id: "team-uuid", key: "RONT", name: "Rondo Test", start_state_id: "state-todo"},
      project: %{id: "project-uuid", name: "Rondo E2E", slug_id: "rondo-e2e-abc123"}
    }
  end

  describe "resolve_team/2" do
    test "returns team id and start state id" do
      states = [
        %{"id" => "state-todo", "name" => "Todo", "type" => "unstarted"},
        %{"id" => "state-wip", "name" => "In Progress", "type" => "started"}
      ]

      graphql = fn query, variables ->
        assert query =~ "RondoE2EResolveTeam"
        assert variables == %{key: "RONT"}
        {:ok, team_payload(states)}
      end

      assert {:ok, team} = LiveE2E.resolve_team("RONT", graphql)
      assert team == %{id: "team-uuid", key: "RONT", name: "Rondo Test", start_state_id: "state-todo"}
    end

    test "errors when the team is missing" do
      graphql = fn _query, _variables -> {:ok, %{"data" => %{"teams" => %{"nodes" => []}}}} end

      assert {:error, {:team_not_found, "RONT"}} = LiveE2E.resolve_team("RONT", graphql)
    end

    test "errors with available state names when required states are missing" do
      graphql = fn _query, _variables ->
        {:ok, team_payload([%{"id" => "s1", "name" => "Backlog", "type" => "backlog"}])}
      end

      assert {:error, {:team_state_missing, "RONT", "Todo", ["Backlog"]}} =
               LiveE2E.resolve_team("RONT", graphql)

      graphql = fn _query, _variables ->
        {:ok, team_payload([%{"id" => "s1", "name" => "Todo", "type" => "unstarted"}])}
      end

      assert {:error, {:team_state_missing, "RONT", "In Progress", ["Todo"]}} =
               LiveE2E.resolve_team("RONT", graphql)
    end
  end

  describe "resolve_project/3" do
    defp project_node(id, team_ids) do
      %{
        "id" => id,
        "name" => "Rondo E2E",
        "slugId" => "#{id}-slug",
        "teams" => %{"nodes" => Enum.map(team_ids, &%{"id" => &1})}
      }
    end

    defp test_team, do: %{id: "team-uuid", key: "RONT", name: "Rondo Test", start_state_id: "state-todo"}

    test "returns project id and slugId for tracker.project_slug" do
      graphql = fn query, variables ->
        assert query =~ "RondoE2EResolveProject"
        assert variables == %{name: "Rondo E2E"}

        {:ok, %{"data" => %{"projects" => %{"nodes" => [project_node("project-uuid", ["team-uuid"])]}}}}
      end

      assert {:ok, project} = LiveE2E.resolve_project("Rondo E2E", test_team(), graphql)
      assert project == %{id: "project-uuid", name: "Rondo E2E", slug_id: "project-uuid-slug"}
    end

    test "skips same-named projects belonging to other teams" do
      graphql = fn _query, _variables ->
        {:ok,
         %{
           "data" => %{
             "projects" => %{
               "nodes" => [project_node("other", ["other-team"]), project_node("ours", ["team-uuid"])]
             }
           }
         }}
      end

      assert {:ok, %{id: "ours"}} = LiveE2E.resolve_project("Rondo E2E", test_team(), graphql)
    end

    test "errors when no matching project belongs to the test team" do
      graphql = fn _query, _variables ->
        {:ok, %{"data" => %{"projects" => %{"nodes" => [project_node("other", ["other-team"])]}}}}
      end

      assert {:error, {:project_not_in_team, "Rondo E2E", "RONT", ["Rondo E2E"]}} =
               LiveE2E.resolve_project("Rondo E2E", test_team(), graphql)
    end

    test "errors when the project is missing" do
      graphql = fn _query, _variables -> {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}} end

      assert {:error, {:project_not_found, "Rondo E2E"}} =
               LiveE2E.resolve_project("Rondo E2E", test_team(), graphql)
    end
  end

  describe "create_issue/2" do
    test "creates a clearly-labeled disposable issue pinned to the start state" do
      parent = self()

      graphql = fn query, variables ->
        send(parent, {:create_issue, query, variables})

        {:ok,
         %{
           "data" => %{
             "issueCreate" => %{
               "success" => true,
               "issue" => %{
                 "id" => "issue-uuid",
                 "identifier" => "RONT-7",
                 "url" => "https://linear.app/x/issue/RONT-7",
                 "state" => %{"name" => "Todo"}
               }
             }
           }
         }}
      end

      assert {:ok, issue} = LiveE2E.create_issue(create_context(), graphql)

      assert issue == %{
               id: "issue-uuid",
               identifier: "RONT-7",
               url: "https://linear.app/x/issue/RONT-7",
               state: "Todo"
             }

      assert_received {:create_issue, query, %{input: input}}
      assert query =~ "RondoE2ECreateIssue"
      assert input.teamId == "team-uuid"
      assert input.projectId == "project-uuid"
      assert input.stateId == "state-todo"
      assert String.starts_with?(input.title, LiveE2E.title_prefix())
      assert input.description =~ LiveE2E.marker_file_name()
      assert input.description =~ LiveE2E.marker_content()
    end

    test "errors with the response body when creation is unsuccessful" do
      body = %{"data" => %{"issueCreate" => %{"success" => false, "issue" => nil}}}
      graphql = fn _query, _variables -> {:ok, body} end

      assert {:error, {:issue_create_failed, ^body}} = LiveE2E.create_issue(create_context(), graphql)
    end
  end

  describe "fetch_issue_state/2" do
    test "returns the current state name" do
      graphql = fn _query, variables ->
        assert variables == %{id: "issue-uuid"}
        {:ok, %{"data" => %{"issue" => %{"state" => %{"name" => "In Progress"}}}}}
      end

      assert {:ok, "In Progress"} = LiveE2E.fetch_issue_state("issue-uuid", graphql)
    end

    test "errors with context when the state is unavailable" do
      body = %{"data" => %{"issue" => nil}}
      graphql = fn _query, _variables -> {:ok, body} end

      assert {:error, {:issue_state_unavailable, "issue-uuid", ^body}} =
               LiveE2E.fetch_issue_state("issue-uuid", graphql)
    end
  end

  describe "cleanup_issue/2" do
    test "deletes the disposable issue" do
      graphql = fn query, variables ->
        assert query =~ "RondoE2EDeleteIssue"
        assert variables == %{id: "issue-uuid"}
        {:ok, %{"data" => %{"issueDelete" => %{"success" => true}}}}
      end

      assert :ok = LiveE2E.cleanup_issue("issue-uuid", graphql)
    end

    test "is best-effort: logs and returns the error when deletion fails" do
      issue = %{id: "issue-uuid", identifier: "RONT-7", url: "https://linear.app/x/issue/RONT-7"}
      graphql = fn _query, _variables -> {:error, {:linear_api_status, 500}} end

      {result, log} =
        with_log(fn -> LiveE2E.cleanup_issue(issue, graphql) end)

      assert {:error, {:linear_request_failed, :cleanup_issue, {:linear_api_status, 500}}} = result
      assert log =~ "live E2E cleanup failed"
      assert log =~ "RONT-7"
      assert log =~ "delete it manually"
    end

    test "errors when the API reports an unsuccessful delete" do
      body = %{"data" => %{"issueDelete" => %{"success" => false}}}
      graphql = fn _query, _variables -> {:ok, body} end

      assert {:error, {:issue_delete_failed, "issue-uuid", ^body}} =
               LiveE2E.cleanup_issue("issue-uuid", graphql)
    end
  end

  describe "graphql error surfacing" do
    test "wraps GraphQL errors with the failing operation" do
      errors = [%{"message" => "auth"}]
      graphql = fn _query, _variables -> {:ok, %{"errors" => errors, "data" => nil}} end

      assert {:error, {:linear_graphql_errors, :resolve_team, ^errors, _body}} =
               LiveE2E.resolve_team("RONT", graphql)
    end

    test "wraps transport failures and unexpected results with the failing operation" do
      graphql = fn _query, _variables -> {:error, :timeout} end

      assert {:error, {:linear_request_failed, :resolve_project, :timeout}} =
               LiveE2E.resolve_project("Rondo E2E", test_team(), graphql)

      graphql = fn _query, _variables -> :boom end

      assert {:error, {:unexpected_graphql_result, :fetch_issue_state, :boom}} =
               LiveE2E.fetch_issue_state("issue-uuid", graphql)
    end
  end

  describe "issue content helpers" do
    test "issue_title is prefixed and timestamped" do
      title = LiveE2E.issue_title()

      assert String.starts_with?(title, "[rondo-e2e]")
      assert title =~ ~r/\d{4}-\d{2}-\d{2}T/
    end

    test "default description marks the issue as disposable" do
      description = LiveE2E.default_issue_description()

      assert description =~ "Safe to delete"
      assert description =~ LiveE2E.marker_file_name()
    end

    test "state name constants match RunOnce's transition target" do
      assert LiveE2E.start_state_name() == "Todo"
      assert LiveE2E.in_progress_state_name() == "In Progress"
    end
  end
end
