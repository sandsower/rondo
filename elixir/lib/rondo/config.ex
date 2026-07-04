defmodule Rondo.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias NimbleOptions
  alias Rondo.Workflow
  require Logger

  @default_active_states ["Todo", "In Progress"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_poll_interval_ms 30_000
  @default_workspace_root Path.join(System.tmp_dir!(), "rondo_workspaces")
  @default_max_concurrent_agents 10
  @default_worker_max_concurrent_agents_per_host @default_max_concurrent_agents
  @default_hook_timeout_ms 60_000
  @default_gate_timeout_ms 60_000
  @default_agent_adapter "claude_code"
  @default_agent_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_claude_command "claude"
  @default_claude_permission_mode "bypassPermissions"
  @valid_claude_permission_modes ["default", "plan", "acceptEdits", "bypassPermissions"]
  @default_claude_dangerously_skip_permissions true
  @default_claude_max_turns 50
  @default_claude_output_format "stream-json"
  @default_claude_turn_timeout_ms 3_600_000
  @default_claude_stall_timeout_ms 300_000
  @default_pi_command "pi"
  @default_codex_command "codex"
  @default_pi_turn_timeout_ms 3_600_000
  @default_pi_stall_timeout_ms 300_000
  @default_codex_turn_timeout_ms 3_600_000
  @default_codex_stall_timeout_ms 300_000
  @default_action_policy_command "beislid"
  @default_action_policy_run_mode "unattended-auto"
  @valid_action_policy_run_modes ["supervised-auto", "unattended-auto"]
  @default_process_provider_kind "native"
  @default_process_provider_required false
  @valid_process_provider_kinds ["native", "beislid"]
  @default_release_loop_max_pr_risk_level "low"
  @valid_release_loop_pr_risk_levels ["low", "medium", "high"]
  @default_release_loop_review_policy_high_risk_paths [
    "**/config/**",
    "elixir/config/**",
    "**/priv/repo/migrations/**",
    "elixir/priv/repo/migrations/**",
    "**/*_web/**",
    "**/security/**",
    "**/auth/**",
    "**/crypto/**",
    "**/billing/**",
    "**/payment/**",
    "mix.lock"
  ]
  @default_release_loop_review_policy_low_risk_paths [
    "docs/**",
    "test/**",
    "elixir/test/**",
    "elixir/test/support/**",
    "**/*.md",
    "**/*.markdown",
    "**/*.mdx",
    "**/*.rst",
    "README*",
    "CHANGELOG.md"
  ]
  @default_release_loop_review_policy_high_risk_file_count 12
  @default_release_loop_review_policy_high_risk_total_changes 500
  @default_release_loop_review_policy_low_risk_file_count 3
  @default_release_loop_review_policy_low_risk_total_changes 120
  @default_clean_eval_enabled true
  @default_debug false
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_server_host "127.0.0.1"
  @default_github_state_label_prefix "status:"
  @default_escalation_enabled false
  @default_escalation_tiers ["light", "standard", "heavy", "frontier"]
  @default_escalation_max_total_attempts 3
  @default_escalation_report_repair_attempts 2
  @workflow_options_schema NimbleOptions.new!(
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: {:or, [:string, nil]}, default: nil],
                                 endpoint: [type: :string, default: @default_linear_endpoint],
                                 api_key: [type: {:or, [:string, nil]}, default: nil],
                                 project_slug: [type: {:or, [:string, nil]}, default: nil],
                                 repo: [type: {:or, [:string, nil]}, default: nil],
                                 state_label_prefix: [type: :string, default: @default_github_state_label_prefix],
                                 assignee: [type: {:or, [:string, nil]}, default: nil],
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
                                 ],
                                 review_states: [
                                   type: {:list, :string},
                                   default: []
                                 ],
                                 terminal_states: [
                                   type: {:list, :string},
                                   default: @default_terminal_states
                                 ],
                                 label_filter: [
                                   type: {:list, :string},
                                   default: []
                                 ]
                               ]
                             ],
                             polling: [
                               type: :map,
                               default: %{},
                               keys: [
                                 interval_ms: [type: :integer, default: @default_poll_interval_ms]
                               ]
                             ],
                             workspace: [
                               type: :map,
                               default: %{},
                               keys: [
                                 root: [type: {:or, [:string, nil]}, default: @default_workspace_root]
                               ]
                             ],
                             worker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents_per_host: [
                                   type: :integer,
                                   default: @default_worker_max_concurrent_agents_per_host
                                 ],
                                 ssh_hosts: [
                                   type: {:list, :map},
                                   default: []
                                 ]
                               ]
                             ],
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
                                 ],
                                 adapter: [
                                   type: :string,
                                   default: @default_agent_adapter
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_agent_max_turns
                                 ],
                                 max_retry_backoff_ms: [
                                   type: :pos_integer,
                                   default: @default_max_retry_backoff_ms
                                 ],
                                 max_concurrent_agents_by_state: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ]
                               ]
                             ],
                             claude: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_claude_command],
                                 permission_mode: [type: :string, default: @default_claude_permission_mode],
                                 dangerously_skip_permissions: [
                                   type: :boolean,
                                   default: @default_claude_dangerously_skip_permissions
                                 ],
                                 max_turns: [type: :pos_integer, default: @default_claude_max_turns],
                                 output_format: [type: :string, default: @default_claude_output_format],
                                 model: [type: {:or, [:string, nil]}, default: nil],
                                 allowed_tools: [type: {:or, [{:list, :string}, nil]}, default: nil],
                                 turn_timeout_ms: [type: :integer, default: @default_claude_turn_timeout_ms],
                                 stall_timeout_ms: [type: :integer, default: @default_claude_stall_timeout_ms]
                               ]
                             ],
                             pi: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_pi_command],
                                 turn_timeout_ms: [type: :integer, default: @default_pi_turn_timeout_ms],
                                 stall_timeout_ms: [type: :integer, default: @default_pi_stall_timeout_ms]
                               ]
                             ],
                             codex: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_codex_command],
                                 turn_timeout_ms: [type: :integer, default: @default_codex_turn_timeout_ms],
                                 stall_timeout_ms: [type: :integer, default: @default_codex_stall_timeout_ms]
                               ]
                             ],
                             action_policy: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_action_policy_command],
                                 run_mode: [type: :string, default: @default_action_policy_run_mode],
                                 policy_file: [type: {:or, [:string, nil]}, default: nil]
                               ]
                             ],
                             release_loop: [
                               type: :map,
                               default: %{},
                               keys: [
                                 enabled: [type: :boolean, default: false],
                                 pr_review_source: [type: {:or, [:string, nil]}, default: nil],
                                 pr_review_update: [type: {:or, [:string, nil]}, default: nil],
                                 wait_interval_seconds: [type: :pos_integer, default: 60],
                                 run_configured_gates_before_push: [type: :boolean, default: true],
                                 max_pr_risk_level: [
                                   type: :string,
                                   default: @default_release_loop_max_pr_risk_level
                                 ],
                                 review_policy: [
                                   type: :map,
                                   default: %{},
                                   keys: [
                                     high_risk_paths: [
                                       type: {:list, :string},
                                       default: @default_release_loop_review_policy_high_risk_paths
                                     ],
                                     low_risk_paths: [
                                       type: {:list, :string},
                                       default: @default_release_loop_review_policy_low_risk_paths
                                     ],
                                     high_risk_file_count: [
                                       type: :pos_integer,
                                       default: @default_release_loop_review_policy_high_risk_file_count
                                     ],
                                     high_risk_total_changes: [
                                       type: :pos_integer,
                                       default: @default_release_loop_review_policy_high_risk_total_changes
                                     ],
                                     low_risk_file_count: [
                                       type: :pos_integer,
                                       default: @default_release_loop_review_policy_low_risk_file_count
                                     ],
                                     low_risk_total_changes: [
                                       type: :pos_integer,
                                       default: @default_release_loop_review_policy_low_risk_total_changes
                                     ]
                                   ]
                                 ],
                                 review_state: [type: :string, default: "Human Review"],
                                 rework_state: [type: :string, default: "Rework"],
                                 merge_state: [type: :string, default: "Merging"],
                                 done_state: [type: :string, default: "Done"],
                                 closeout: [
                                   type: :map,
                                   default: %{},
                                   keys: [
                                     merge: [
                                       type: :map,
                                       default: %{},
                                       keys: [
                                         mode: [type: :string, default: "auto"],
                                         method: [type: :string, default: "merge"],
                                         delete_branch: [type: :boolean, default: true]
                                       ]
                                     ]
                                   ]
                                 ]
                               ]
                             ],
                             process_provider: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: :string, default: @default_process_provider_kind],
                                 required: [type: :boolean, default: @default_process_provider_required],
                                 artifact_path: [type: {:or, [:string, nil]}, default: nil]
                               ]
                             ],
                             model_routing: [
                               type: :map,
                               default: %{},
                               keys: [
                                 tiers: [type: :map, default: %{}],
                                 floor: [type: :map, default: %{}],
                                 defaults: [type: :map, default: %{}],
                                 step_hints: [type: :map, default: %{}],
                                 profiles: [type: {:map, :string, :any}, default: %{}]
                               ]
                             ],
                             escalation: [
                               type: :map,
                               default: %{},
                               keys: [
                                 enabled: [type: :boolean, default: @default_escalation_enabled],
                                 tiers: [type: {:list, :string}, default: @default_escalation_tiers],
                                 max_total_attempts: [
                                   type: :pos_integer,
                                   default: @default_escalation_max_total_attempts
                                 ],
                                 token_budget: [type: {:or, [:pos_integer, nil]}, default: nil],
                                 report_repair_attempts: [
                                   type: :pos_integer,
                                   default: @default_escalation_report_repair_attempts
                                 ]
                               ]
                             ],
                             hooks: [
                               type: :map,
                               default: %{},
                               keys: [
                                 after_create: [type: {:or, [:string, nil]}, default: nil],
                                 before_run: [type: {:or, [:string, nil]}, default: nil],
                                 after_run: [type: {:or, [:string, nil]}, default: nil],
                                 before_remove: [type: {:or, [:string, nil]}, default: nil],
                                 timeout_ms: [type: :pos_integer, default: @default_hook_timeout_ms]
                               ]
                             ],
                             gates: [
                               type: {:list, :map},
                               default: []
                             ],
                             gate_reuse: [
                               type: :map,
                               default: %{enabled: true},
                               keys: [
                                 enabled: [type: :boolean, default: true]
                               ]
                             ],
                             clean_eval: [
                               type: :map,
                               default: %{},
                               keys: [
                                 enabled: [type: :boolean, default: @default_clean_eval_enabled],
                                 base_ref: [type: {:or, [:string, nil]}, default: nil],
                                 # nil (absent) falls back to top-level gates; an
                                 # explicit [] means apply-only clean evaluation.
                                 gates: [type: {:or, [{:list, :map}, nil]}, default: nil]
                               ]
                             ],
                             observability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 dashboard_enabled: [
                                   type: :boolean,
                                   default: @default_observability_enabled
                                 ],
                                 refresh_ms: [
                                   type: :integer,
                                   default: @default_observability_refresh_ms
                                 ],
                                 render_interval_ms: [
                                   type: :integer,
                                   default: @default_observability_render_interval_ms
                                 ]
                               ]
                             ],
                             server: [
                               type: :map,
                               default: %{},
                               keys: [
                                 port: [type: {:or, [:non_neg_integer, nil]}, default: nil],
                                 host: [type: :string, default: @default_server_host]
                               ]
                             ]
                           )

  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }
  @type gate :: %{
          name: String.t(),
          command: String.t(),
          timeout_ms: pos_integer(),
          action_id: String.t() | nil,
          action_classes: [String.t()]
        }
  @type action_policy :: %{
          command: String.t(),
          run_mode: String.t(),
          policy_file: String.t() | nil
        }
  @type gate_reuse :: %{
          enabled: boolean()
        }
  @type release_loop_closeout_merge :: %{
          mode: String.t(),
          method: String.t(),
          delete_branch: boolean()
        }
  @type release_loop_closeout :: %{
          merge: release_loop_closeout_merge()
        }
  @type release_loop_review_policy :: %{
          high_risk_paths: [String.t()],
          low_risk_paths: [String.t()],
          high_risk_file_count: pos_integer(),
          high_risk_total_changes: pos_integer(),
          low_risk_file_count: pos_integer(),
          low_risk_total_changes: pos_integer()
        }
  @type release_loop :: %{
          enabled: boolean(),
          pr_review_source: String.t() | nil,
          pr_review_update: String.t() | nil,
          wait_interval_seconds: pos_integer(),
          run_configured_gates_before_push: boolean(),
          max_pr_risk_level: String.t(),
          review_policy: release_loop_review_policy(),
          review_state: String.t(),
          rework_state: String.t(),
          merge_state: String.t(),
          done_state: String.t(),
          closeout: release_loop_closeout()
        }
  @type process_provider :: %{
          kind: String.t(),
          required: boolean(),
          artifact_path: Path.t() | nil
        }
  @type model_routing :: map()

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    get_in(validated_workflow_options(), [:tracker, :kind])
  end

  @spec linear_endpoint() :: String.t()
  def linear_endpoint do
    get_in(validated_workflow_options(), [:tracker, :endpoint])
  end

  @spec linear_api_token() :: String.t() | nil
  def linear_api_token do
    validated_workflow_options()
    |> get_in([:tracker, :api_key])
    |> resolve_secret_env_value(System.get_env("LINEAR_API_KEY"))
    |> normalize_secret_value()
  end

  @spec linear_project_slug() :: String.t() | nil
  def linear_project_slug do
    get_in(validated_workflow_options(), [:tracker, :project_slug])
  end

  @spec linear_assignee() :: String.t() | nil
  def linear_assignee do
    validated_workflow_options()
    |> get_in([:tracker, :assignee])
    |> resolve_env_value(System.get_env("LINEAR_ASSIGNEE"))
    |> normalize_secret_value()
  end

  @spec tracker_repo() :: String.t() | nil
  def tracker_repo do
    get_in(validated_workflow_options(), [:tracker, :repo])
  end

  @spec tracker_state_label_prefix() :: String.t()
  def tracker_state_label_prefix do
    get_in(validated_workflow_options(), [:tracker, :state_label_prefix])
  end

  @spec tracker_active_states() :: [String.t()]
  def tracker_active_states do
    get_in(validated_workflow_options(), [:tracker, :active_states])
  end

  @spec tracker_review_states() :: [String.t()]
  def tracker_review_states do
    get_in(validated_workflow_options(), [:tracker, :review_states])
  end

  @spec tracker_terminal_states() :: [String.t()]
  def tracker_terminal_states do
    get_in(validated_workflow_options(), [:tracker, :terminal_states])
  end

  @spec linear_active_states() :: [String.t()]
  def linear_active_states, do: tracker_active_states()

  @spec linear_review_states() :: [String.t()]
  def linear_review_states, do: tracker_review_states()

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states, do: tracker_terminal_states()

  @spec tracker_label_filter() :: [String.t()]
  def tracker_label_filter do
    get_in(validated_workflow_options(), [:tracker, :label_filter])
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    get_in(validated_workflow_options(), [:polling, :interval_ms])
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    validated_workflow_options()
    |> get_in([:workspace, :root])
    |> resolve_path_value(@default_workspace_root)
  end

  @spec worker_max_concurrent_agents_per_host() :: pos_integer()
  def worker_max_concurrent_agents_per_host do
    get_in(validated_workflow_options(), [:worker, :max_concurrent_agents_per_host])
  end

  @spec worker_ssh_hosts() :: [map()]
  def worker_ssh_hosts do
    get_in(validated_workflow_options(), [:worker, :ssh_hosts]) || []
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = get_in(validated_workflow_options(), [:hooks])

    %{
      after_create: Map.get(hooks, :after_create),
      before_run: Map.get(hooks, :before_run),
      after_run: Map.get(hooks, :after_run),
      before_remove: Map.get(hooks, :before_remove),
      timeout_ms: Map.get(hooks, :timeout_ms)
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    get_in(validated_workflow_options(), [:hooks, :timeout_ms])
  end

  @spec gates() :: [gate()]
  def gates do
    validated_workflow_options()
    |> Map.get(:gates, [])
    |> Enum.map(&normalize_gate/1)
  end

  @spec gate_reuse_enabled?() :: boolean()
  def gate_reuse_enabled? do
    validated_workflow_options()
    |> get_in([:gate_reuse, :enabled])
  end

  defp normalize_gate(gate) do
    %{
      name: Map.fetch!(gate, :name),
      command: Map.fetch!(gate, :command),
      timeout_ms: Map.get(gate, :timeout_ms, @default_gate_timeout_ms),
      action_id: Map.get(gate, :action_id),
      action_classes: Map.get(gate, :action_classes, ["read"])
    }
  end

  @spec clean_eval_enabled?() :: boolean()
  def clean_eval_enabled? do
    get_in(validated_workflow_options(), [:clean_eval, :enabled])
  end

  @spec clean_eval_base_ref() :: String.t() | nil
  def clean_eval_base_ref do
    get_in(validated_workflow_options(), [:clean_eval, :base_ref])
  end

  @spec clean_eval_gates() :: [gate()]
  def clean_eval_gates do
    validated_workflow_options()
    |> get_in([:clean_eval, :gates])
    |> case do
      # An explicit `clean_eval.gates: []` means apply-only evaluation; only an
      # absent key falls back to the top-level gates.
      gates when is_list(gates) -> Enum.map(gates, &normalize_gate/1)
      _absent -> gates()
    end
  end

  @spec escalation_enabled?() :: boolean()
  def escalation_enabled? do
    get_in(validated_workflow_options(), [:escalation, :enabled])
  end

  @spec escalation_tiers() :: [String.t()]
  def escalation_tiers do
    get_in(validated_workflow_options(), [:escalation, :tiers]) || @default_escalation_tiers
  end

  @spec escalation_max_total_attempts() :: pos_integer()
  def escalation_max_total_attempts do
    get_in(validated_workflow_options(), [:escalation, :max_total_attempts]) ||
      @default_escalation_max_total_attempts
  end

  @spec escalation_token_budget() :: pos_integer() | nil
  def escalation_token_budget do
    get_in(validated_workflow_options(), [:escalation, :token_budget])
  end

  @spec escalation_report_repair_attempts() :: pos_integer()
  def escalation_report_repair_attempts do
    get_in(validated_workflow_options(), [:escalation, :report_repair_attempts]) ||
      @default_escalation_report_repair_attempts
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
  end

  @spec agent_adapter() :: String.t()
  def agent_adapter do
    get_in(validated_workflow_options(), [:agent, :adapter])
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    get_in(validated_workflow_options(), [:agent, :max_turns])
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])
    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec claude_command() :: String.t()
  def claude_command do
    get_in(validated_workflow_options(), [:claude, :command])
  end

  @spec claude_turn_timeout_ms() :: pos_integer()
  def claude_turn_timeout_ms do
    get_in(validated_workflow_options(), [:claude, :turn_timeout_ms])
  end

  @spec claude_stall_timeout_ms() :: non_neg_integer()
  def claude_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:claude, :stall_timeout_ms])
    |> max(0)
  end

  @spec claude_permission_mode() :: String.t()
  def claude_permission_mode do
    get_in(validated_workflow_options(), [:claude, :permission_mode])
  end

  @spec claude_dangerously_skip_permissions?() :: boolean()
  def claude_dangerously_skip_permissions? do
    get_in(validated_workflow_options(), [:claude, :dangerously_skip_permissions])
  end

  @spec claude_max_turns() :: pos_integer()
  def claude_max_turns do
    get_in(validated_workflow_options(), [:claude, :max_turns])
  end

  @spec claude_output_format() :: String.t()
  def claude_output_format do
    get_in(validated_workflow_options(), [:claude, :output_format])
  end

  @spec claude_model() :: String.t() | nil
  def claude_model do
    get_in(validated_workflow_options(), [:claude, :model])
  end

  @spec claude_allowed_tools() :: [String.t()] | nil
  def claude_allowed_tools do
    get_in(validated_workflow_options(), [:claude, :allowed_tools])
  end

  @spec pi_command() :: String.t()
  def pi_command do
    get_in(validated_workflow_options(), [:pi, :command])
  end

  @spec codex_command() :: String.t()
  def codex_command do
    get_in(validated_workflow_options(), [:codex, :command])
  end

  @spec action_policy() :: action_policy()
  def action_policy do
    policy = get_in(validated_workflow_options(), [:action_policy])

    %{
      command: Map.get(policy, :command),
      run_mode: Map.get(policy, :run_mode),
      policy_file: Map.get(policy, :policy_file)
    }
  end

  @spec release_loop() :: release_loop()
  def release_loop do
    loop = get_in(validated_workflow_options(), [:release_loop])
    closeout = Map.get(loop, :closeout, %{})
    merge = Map.get(closeout, :merge, %{})

    %{
      enabled: Map.get(loop, :enabled),
      pr_review_source: Map.get(loop, :pr_review_source),
      pr_review_update: Map.get(loop, :pr_review_update),
      wait_interval_seconds: Map.get(loop, :wait_interval_seconds),
      run_configured_gates_before_push: Map.get(loop, :run_configured_gates_before_push),
      max_pr_risk_level: Map.get(loop, :max_pr_risk_level),
      review_policy: Map.get(loop, :review_policy),
      review_state: Map.get(loop, :review_state),
      rework_state: Map.get(loop, :rework_state),
      merge_state: Map.get(loop, :merge_state),
      done_state: Map.get(loop, :done_state),
      closeout: %{merge: %{mode: Map.get(merge, :mode), method: Map.get(merge, :method), delete_branch: Map.get(merge, :delete_branch)}}
    }
  end

  @spec release_loop_enabled?() :: boolean()
  def release_loop_enabled?, do: release_loop().enabled

  @spec release_loop_pr_review_source() :: String.t() | nil
  def release_loop_pr_review_source, do: release_loop().pr_review_source

  @spec release_loop_pr_review_update() :: String.t() | nil
  def release_loop_pr_review_update, do: release_loop().pr_review_update

  @spec release_loop_wait_interval_seconds() :: pos_integer()
  def release_loop_wait_interval_seconds, do: release_loop().wait_interval_seconds

  @spec release_loop_run_configured_gates_before_push?() :: boolean()
  def release_loop_run_configured_gates_before_push?, do: release_loop().run_configured_gates_before_push

  @spec release_loop_max_pr_risk_level() :: String.t()
  def release_loop_max_pr_risk_level, do: release_loop().max_pr_risk_level

  @spec release_loop_review_policy() :: release_loop_review_policy()
  def release_loop_review_policy, do: release_loop().review_policy

  @spec release_loop_review_state() :: String.t()
  def release_loop_review_state, do: release_loop().review_state

  @spec release_loop_rework_state() :: String.t()
  def release_loop_rework_state, do: release_loop().rework_state

  @spec release_loop_merge_state() :: String.t()
  def release_loop_merge_state, do: release_loop().merge_state

  @spec release_loop_done_state() :: String.t()
  def release_loop_done_state, do: release_loop().done_state

  @spec release_loop_merge_mode() :: String.t()
  def release_loop_merge_mode do
    get_in(validated_workflow_options(), [:release_loop, :closeout, :merge, :mode])
  end

  @spec release_loop_merge_method() :: String.t()
  def release_loop_merge_method do
    get_in(validated_workflow_options(), [:release_loop, :closeout, :merge, :method])
  end

  @spec release_loop_delete_branch?() :: boolean()
  def release_loop_delete_branch? do
    get_in(validated_workflow_options(), [:release_loop, :closeout, :merge, :delete_branch])
  end

  @spec action_policy_command() :: String.t()
  def action_policy_command do
    get_in(validated_workflow_options(), [:action_policy, :command])
  end

  @spec action_policy_run_mode() :: String.t()
  def action_policy_run_mode do
    get_in(validated_workflow_options(), [:action_policy, :run_mode])
  end

  @spec action_policy_policy_file() :: String.t() | nil
  def action_policy_policy_file do
    get_in(validated_workflow_options(), [:action_policy, :policy_file])
  end

  @spec process_provider() :: process_provider()
  def process_provider do
    provider = get_in(validated_workflow_options(), [:process_provider])

    %{
      kind: Map.get(provider, :kind),
      required: Map.get(provider, :required),
      artifact_path: Map.get(provider, :artifact_path)
    }
  end

  @spec process_provider_kind() :: String.t()
  def process_provider_kind do
    get_in(validated_workflow_options(), [:process_provider, :kind])
  end

  @spec process_provider_required?() :: boolean()
  def process_provider_required? do
    get_in(validated_workflow_options(), [:process_provider, :required])
  end

  @spec process_provider_artifact_path() :: Path.t() | nil
  def process_provider_artifact_path do
    get_in(validated_workflow_options(), [:process_provider, :artifact_path])
  end

  @spec model_routing() :: model_routing()
  def model_routing do
    get_in(validated_workflow_options(), [:model_routing]) || %{}
  end

  @spec pi_turn_timeout_ms() :: pos_integer()
  def pi_turn_timeout_ms do
    get_in(validated_workflow_options(), [:pi, :turn_timeout_ms])
  end

  @spec pi_stall_timeout_ms() :: non_neg_integer()
  def pi_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:pi, :stall_timeout_ms])
    |> max(0)
  end

  @spec codex_turn_timeout_ms() :: pos_integer()
  def codex_turn_timeout_ms do
    get_in(validated_workflow_options(), [:codex, :turn_timeout_ms])
  end

  @spec codex_stall_timeout_ms() :: non_neg_integer()
  def codex_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:codex, :stall_timeout_ms])
    |> max(0)
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      {:error, reason} ->
        log_workflow_load_failure(reason)
        @default_prompt_template
    end
  end

  @spec debug?() :: boolean()
  def debug? do
    Application.get_env(:rondo, :debug, @default_debug)
  end

  @spec set_debug(boolean()) :: :ok
  def set_debug(enabled) when is_boolean(enabled) do
    Application.put_env(:rondo, :debug, enabled)
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    get_in(validated_workflow_options(), [:observability, :dashboard_enabled])
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    get_in(validated_workflow_options(), [:observability, :refresh_ms])
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    get_in(validated_workflow_options(), [:observability, :render_interval_ms])
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:rondo, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        get_in(validated_workflow_options(), [:server, :port])
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    get_in(validated_workflow_options(), [:server, :host])
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    path = Workflow.workflow_file_path()

    with {:ok, workflow} <- Workflow.load(path) do
      validate_workflow(workflow, path)
    end
  end

  @spec validate_workflow(workflow_payload(), Path.t()) :: :ok | {:error, term()}
  def validate_workflow(workflow, path \\ Workflow.workflow_file_path()) do
    with {:ok, options} <- validate_workflow_options(workflow, path),
         :ok <- require_tracker_kind(options, path),
         :ok <- require_linear_token(options, path),
         :ok <- require_linear_project(options, path),
         :ok <- require_github_repo(options, path) do
      require_agent_command(options, path)
    end
  end

  @spec format_validation_error(term()) :: String.t()
  def format_validation_error({:invalid_workflow_config, path, errors}) when is_list(errors) do
    fields = Enum.map_join(errors, ", ", &Map.fetch!(&1, :path))

    details =
      Enum.map_join(errors, "; ", fn error ->
        "#{Map.fetch!(error, :path)}: #{Map.fetch!(error, :message)}"
      end)

    "Invalid WORKFLOW.md config path=#{path} fields=#{fields} errors=#{details}"
  end

  def format_validation_error(reason), do: inspect(reason)

  defp require_tracker_kind(options) do
    case get_in(options, [:tracker, :kind]) do
      "linear" -> :ok
      "memory" -> :ok
      "github" -> :ok
      nil -> {:error, :missing_tracker_kind}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp require_linear_token(options) do
    case get_in(options, [:tracker, :kind]) do
      "linear" ->
        options
        |> get_in([:tracker, :api_key])
        |> resolve_secret_env_value(System.get_env("LINEAR_API_KEY"))
        |> normalize_secret_value()
        |> is_binary()
        |> case do
          true -> :ok
          false -> {:error, :missing_linear_api_token}
        end

      _ ->
        :ok
    end
  end

  defp require_linear_project(options) do
    case get_in(options, [:tracker, :kind]) do
      "linear" ->
        if is_binary(get_in(options, [:tracker, :project_slug])) do
          :ok
        else
          {:error, :missing_linear_project_slug}
        end

      _ ->
        :ok
    end
  end

  defp require_github_repo(options) do
    case get_in(options, [:tracker, :kind]) do
      "github" ->
        options
        |> get_in([:tracker, :repo])
        |> valid_github_repo?()
        |> case do
          true -> :ok
          false -> {:error, :missing_github_repo}
        end

      _ ->
        :ok
    end
  end

  defp valid_github_repo?(repo) when is_binary(repo) do
    String.match?(String.trim(repo), ~r/^[^\s\/]+\/[^\s\/]+$/)
  end

  defp valid_github_repo?(_repo), do: false

  defp require_claude_command(options) do
    require_command(options, [:claude, :command], :missing_claude_command)
  end

  defp require_pi_command(options) do
    require_command(options, [:pi, :command], :missing_pi_command)
  end

  defp require_codex_command(options) do
    require_command(options, [:codex, :command], :missing_codex_command)
  end

  defp require_command(options, path, error) do
    case get_in(options, path) do
      command when is_binary(command) ->
        if byte_size(String.trim(command)) > 0 do
          :ok
        else
          {:error, error}
        end

      _ ->
        {:error, error}
    end
  end

  defp require_tracker_kind(options, path) do
    case require_tracker_kind(options) do
      :ok ->
        :ok

      {:error, :missing_tracker_kind} ->
        {:error, invalid_workflow_config(path, [config_error("tracker.kind", nil, "is required")])}

      {:error, {:unsupported_tracker_kind, kind}} ->
        error = config_error("tracker.kind", kind, "must be linear, memory, or github")
        {:error, invalid_workflow_config(path, [error])}
    end
  end

  defp require_linear_token(options, path) do
    case require_linear_token(options) do
      :ok ->
        :ok

      {:error, :missing_linear_api_token} ->
        error = config_error("tracker.api_key", nil, "is required for linear tracker")
        {:error, invalid_workflow_config(path, [error])}
    end
  end

  defp require_linear_project(options, path) do
    case require_linear_project(options) do
      :ok ->
        :ok

      {:error, :missing_linear_project_slug} ->
        error = config_error("tracker.project_slug", nil, "is required for linear tracker")
        {:error, invalid_workflow_config(path, [error])}
    end
  end

  defp require_github_repo(options, path) do
    case require_github_repo(options) do
      :ok ->
        :ok

      {:error, :missing_github_repo} ->
        error = config_error("tracker.repo", nil, "is required for github tracker")
        {:error, invalid_workflow_config(path, [error])}
    end
  end

  defp require_agent_command(options, path) do
    case get_in(options, [:agent, :adapter]) do
      "claude_code" -> require_claude_command(options, path)
      "pi" -> require_pi_command(options, path)
      "codex" -> require_codex_command(options, path)
      adapter -> {:error, invalid_workflow_config(path, [unsupported_adapter_error(adapter)])}
    end
  end

  defp unsupported_adapter_error(adapter) do
    config_error("agent.adapter", adapter, "unsupported agent adapter; must be claude_code, pi, or codex")
  end

  defp require_claude_command(options, path) do
    case require_claude_command(options) do
      :ok ->
        :ok

      {:error, :missing_claude_command} ->
        error = config_error("claude.command", nil, "is required")
        {:error, invalid_workflow_config(path, [error])}
    end
  end

  defp require_pi_command(options, path) do
    case require_pi_command(options) do
      :ok ->
        :ok

      {:error, :missing_pi_command} ->
        error = config_error("pi.command", nil, "is required")
        {:error, invalid_workflow_config(path, [error])}
    end
  end

  defp require_codex_command(options, path) do
    case require_codex_command(options) do
      :ok ->
        :ok

      {:error, :missing_codex_command} ->
        error = config_error("codex.command", nil, "is required")
        {:error, invalid_workflow_config(path, [error])}
    end
  end

  defp validated_workflow_options do
    case current_workflow() do
      {:ok, workflow} ->
        case validate_workflow_options(workflow, Workflow.workflow_file_path()) do
          {:ok, options} ->
            options

          {:error, reason} ->
            raise ArgumentError, format_validation_error(reason)
        end

      {:error, reason} ->
        log_workflow_load_failure(reason)
        workflow_default_options()
    end
  end

  defp validate_workflow_options(%{config: config}, path) when is_map(config) do
    config = normalize_keys(config)

    case validate_raw_config(config) do
      [] ->
        config
        |> extract_workflow_options()
        |> NimbleOptions.validate(@workflow_options_schema)
        |> case do
          {:ok, options} ->
            {:ok, options}

          {:error, %NimbleOptions.ValidationError{} = error} ->
            {:error, invalid_workflow_config(path, [nimble_error(error)])}
        end

      errors ->
        {:error, invalid_workflow_config(path, errors)}
    end
  end

  defp validate_workflow_options(_workflow, path) do
    {:error, invalid_workflow_config(path, [config_error("workflow", nil, "must include a config map")])}
  end

  defp extract_workflow_options(config) do
    config =
      warn_unknown_config_keys("workflow", config, [
        "tracker",
        "polling",
        "workspace",
        "worker",
        "agent",
        "claude",
        "pi",
        "codex",
        "action_policy",
        "release_loop",
        "process_provider",
        "model_routing",
        "escalation",
        "hooks",
        "gates",
        "gate_reuse",
        "clean_eval",
        "observability",
        "server"
      ])

    %{
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      worker: extract_worker_options(section_map(config, "worker")),
      agent: extract_agent_options(section_map(config, "agent")),
      claude: extract_claude_options(section_map(config, "claude")),
      pi: extract_pi_options(section_map(config, "pi")),
      codex: extract_codex_options(section_map(config, "codex")),
      action_policy: extract_action_policy_options(section_map(config, "action_policy")),
      release_loop: extract_release_loop_options(section_map(config, "release_loop")),
      process_provider: extract_process_provider_options(section_map(config, "process_provider")),
      model_routing: extract_model_routing_options(section_map(config, "model_routing")),
      escalation: extract_escalation_options(section_map(config, "escalation")),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      gates: extract_gates_options(Map.get(config, "gates"), "gates"),
      gate_reuse: extract_gate_reuse_options(section_map(config, "gate_reuse")),
      clean_eval: extract_clean_eval_options(section_map(config, "clean_eval")),
      observability: extract_observability_options(section_map(config, "observability")),
      server: extract_server_options(section_map(config, "server"))
    }
  end

  defp extract_tracker_options(section) do
    section =
      warn_unknown_config_keys("tracker", section, [
        "kind",
        "endpoint",
        "api_key",
        "project_slug",
        "repo",
        "state_label_prefix",
        "assignee",
        "active_states",
        "review_states",
        "terminal_states",
        "label_filter"
      ])

    %{}
    |> put_if_present(:kind, normalize_tracker_kind(scalar_string_value(Map.get(section, "kind"))))
    |> put_if_present(:endpoint, scalar_string_value(Map.get(section, "endpoint")))
    |> put_if_present(:api_key, binary_value(Map.get(section, "api_key"), allow_empty: true))
    |> put_if_present(:project_slug, scalar_string_value(Map.get(section, "project_slug")))
    |> put_if_present(:repo, scalar_string_value(Map.get(section, "repo")))
    |> put_if_present(:state_label_prefix, scalar_string_value(Map.get(section, "state_label_prefix")))
    |> put_if_present(:assignee, binary_value(Map.get(section, "assignee")))
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:review_states, csv_value(Map.get(section, "review_states")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
    |> put_if_present(:label_filter, label_filter_value(Map.get(section, "label_filter")))
  end

  defp extract_polling_options(section) do
    section = warn_unknown_config_keys("polling", section, ["interval_ms"])

    %{}
    |> put_if_present(:interval_ms, integer_value(Map.get(section, "interval_ms")))
  end

  defp extract_workspace_options(section) do
    section = warn_unknown_config_keys("workspace", section, ["root"])

    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_worker_options(section) do
    section = warn_unknown_config_keys("worker", section, ["max_concurrent_agents_per_host", "ssh_hosts"])

    %{}
    |> put_if_present(
      :max_concurrent_agents_per_host,
      positive_integer_value(Map.get(section, "max_concurrent_agents_per_host"))
    )
    |> put_if_present(:ssh_hosts, worker_hosts_value(Map.get(section, "ssh_hosts"), "worker.ssh_hosts"))
  end

  defp extract_agent_options(section) do
    section =
      warn_unknown_config_keys("agent", section, [
        "max_concurrent_agents",
        "adapter",
        "max_turns",
        "max_retry_backoff_ms",
        "max_concurrent_agents_by_state"
      ])

    %{}
    |> put_if_present(:max_concurrent_agents, integer_value(Map.get(section, "max_concurrent_agents")))
    |> put_if_present(:adapter, command_value(Map.get(section, "adapter")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:max_retry_backoff_ms, positive_integer_value(Map.get(section, "max_retry_backoff_ms")))
    |> put_if_present(
      :max_concurrent_agents_by_state,
      state_limits_value(Map.get(section, "max_concurrent_agents_by_state"))
    )
  end

  defp extract_claude_options(section) do
    section =
      warn_unknown_config_keys("claude", section, [
        "command",
        "permission_mode",
        "dangerously_skip_permissions",
        "max_turns",
        "output_format",
        "model",
        "allowed_tools",
        "turn_timeout_ms",
        "stall_timeout_ms"
      ])

    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:permission_mode, scalar_string_value(Map.get(section, "permission_mode")))
    |> put_if_present(:dangerously_skip_permissions, boolean_value(Map.get(section, "dangerously_skip_permissions")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:output_format, scalar_string_value(Map.get(section, "output_format")))
    |> put_if_present(:model, scalar_string_value(Map.get(section, "model")))
    |> put_if_present(:allowed_tools, tools_list_value(Map.get(section, "allowed_tools")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
  end

  defp extract_pi_options(section) do
    section = warn_unknown_config_keys("pi", section, ["command", "turn_timeout_ms", "stall_timeout_ms"])

    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
  end

  defp extract_codex_options(section) do
    section = warn_unknown_config_keys("codex", section, ["command", "turn_timeout_ms", "stall_timeout_ms"])

    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
  end

  defp extract_action_policy_options(section) do
    section = warn_unknown_config_keys("action_policy", section, ["command", "run_mode", "policy_file"])

    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:run_mode, scalar_string_value(Map.get(section, "run_mode")))
    |> put_if_present(:policy_file, policy_file_value(Map.get(section, "policy_file")))
  end

  defp extract_release_loop_options(section) do
    section =
      warn_unknown_config_keys("release_loop", section, [
        "enabled",
        "pr_review_source",
        "pr_review_update",
        "wait_interval_seconds",
        "run_configured_gates_before_push",
        "max_pr_risk_level",
        "review_policy",
        "review_state",
        "rework_state",
        "merge_state",
        "done_state",
        "closeout"
      ])

    closeout = section_map(section, "closeout")
    closeout = warn_unknown_config_keys("release_loop.closeout", closeout, ["merge"])
    merge = section_map(closeout, "merge")
    merge = warn_unknown_config_keys("release_loop.closeout.merge", merge, ["mode", "method", "delete_branch"])

    %{}
    |> put_if_present(:enabled, boolean_value(Map.get(section, "enabled")))
    |> put_if_present(:pr_review_source, command_value(Map.get(section, "pr_review_source")))
    |> put_if_present(:pr_review_update, command_value(Map.get(section, "pr_review_update")))
    |> put_if_present(:wait_interval_seconds, positive_integer_value(Map.get(section, "wait_interval_seconds")))
    |> put_if_present(:run_configured_gates_before_push, boolean_value(Map.get(section, "run_configured_gates_before_push")))
    |> put_if_present(:max_pr_risk_level, normalized_release_loop_pr_risk_level(Map.get(section, "max_pr_risk_level")))
    |> put_if_present(:review_policy, extract_release_loop_review_policy_options(section_map(section, "review_policy")))
    |> put_if_present(:review_state, scalar_string_value(Map.get(section, "review_state")))
    |> put_if_present(:rework_state, scalar_string_value(Map.get(section, "rework_state")))
    |> put_if_present(:merge_state, scalar_string_value(Map.get(section, "merge_state")))
    |> put_if_present(:done_state, scalar_string_value(Map.get(section, "done_state")))
    |> put_if_present(
      :closeout,
      %{}
      |> put_if_present(
        :merge,
        %{}
        |> put_if_present(:mode, scalar_string_value(Map.get(merge, "mode")))
        |> put_if_present(:method, scalar_string_value(Map.get(merge, "method")))
        |> put_if_present(:delete_branch, boolean_value(Map.get(merge, "delete_branch")))
      )
    )
  end

  defp extract_release_loop_review_policy_options(section) do
    section =
      warn_unknown_config_keys("release_loop.review_policy", section, [
        "high_risk_paths",
        "low_risk_paths",
        "high_risk_file_count",
        "high_risk_total_changes",
        "low_risk_file_count",
        "low_risk_total_changes"
      ])

    %{}
    |> put_if_present(:high_risk_paths, path_pattern_list_value(Map.get(section, "high_risk_paths")))
    |> put_if_present(:low_risk_paths, path_pattern_list_value(Map.get(section, "low_risk_paths")))
    |> put_if_present(:high_risk_file_count, positive_integer_value(Map.get(section, "high_risk_file_count")))
    |> put_if_present(:high_risk_total_changes, positive_integer_value(Map.get(section, "high_risk_total_changes")))
    |> put_if_present(:low_risk_file_count, positive_integer_value(Map.get(section, "low_risk_file_count")))
    |> put_if_present(:low_risk_total_changes, positive_integer_value(Map.get(section, "low_risk_total_changes")))
  end

  defp normalized_release_loop_pr_risk_level(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalized_release_loop_pr_risk_level(_value), do: :omit

  defp path_pattern_list_value(value) when is_list(value) do
    case csv_value(value) do
      :omit -> []
      patterns -> patterns
    end
  end

  defp path_pattern_list_value(value) when is_binary(value), do: csv_value(value)
  defp path_pattern_list_value(_value), do: :omit

  defp policy_file_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> Path.expand(trimmed)
    end
  end

  defp policy_file_value(_value), do: :omit

  defp extract_process_provider_options(section) do
    section = warn_unknown_config_keys("process_provider", section, ["kind", "required", "artifact_path"])

    %{}
    |> put_if_present(:kind, scalar_string_value(Map.get(section, "kind")))
    |> put_if_present(:required, boolean_value(Map.get(section, "required")))
    |> put_if_present(:artifact_path, binary_value(Map.get(section, "artifact_path")))
  end

  defp extract_model_routing_options(section) when is_map(section) do
    section = warn_unknown_config_keys("model_routing", section, ["tiers", "floor", "defaults", "step_hints", "profiles"])

    %{}
    |> put_if_present(:tiers, normalize_model_routing_tiers(Map.get(section, "tiers")))
    |> put_if_present(:floor, normalize_model_routing_map(Map.get(section, "floor"), "model_routing.floor"))
    |> put_if_present(:defaults, normalize_model_routing_map(Map.get(section, "defaults"), "model_routing.defaults"))
    |> put_if_present(:step_hints, normalize_model_routing_step_hints(model_routing_step_hints_value(section), "model_routing.step_hints"))
    |> put_if_present(:profiles, normalize_model_routing_profiles(Map.get(section, "profiles")))
  end

  defp extract_escalation_options(section) when is_map(section) do
    section = warn_unknown_config_keys("escalation", section, ["enabled", "tiers", "max_total_attempts", "token_budget", "report_repair_attempts"])

    %{}
    |> put_if_present(:enabled, boolean_value(Map.get(section, "enabled")))
    |> put_if_present(:tiers, tier_list_value(Map.get(section, "tiers")))
    |> put_if_present(:max_total_attempts, positive_integer_value(Map.get(section, "max_total_attempts")))
    |> put_if_present(:token_budget, positive_integer_value(Map.get(section, "token_budget")))
    |> put_if_present(:report_repair_attempts, positive_integer_value(Map.get(section, "report_repair_attempts")))
  end

  defp normalize_model_routing_tiers(tiers) when is_map(tiers) do
    tiers = warn_unknown_config_keys("model_routing.tiers", tiers, ["light", "standard", "heavy", "frontier"])

    tiers
    |> Enum.reduce(%{}, fn {tier, candidates}, acc ->
      case normalize_tier_key(tier) do
        nil -> acc
        normalized -> Map.put(acc, normalized, normalize_model_routing_candidates(candidates, "model_routing.tiers.#{normalize_key(tier)}"))
      end
    end)
  end

  defp normalize_model_routing_tiers(_tiers), do: :omit

  defp model_routing_step_hints_value(section) when is_map(section) do
    if Map.has_key?(section, "step_hints"), do: Map.get(section, "step_hints"), else: :omit
  end

  defp normalize_model_routing_step_hints(hints, section_name) when is_map(hints) do
    hints = warn_unknown_config_keys(section_name, hints, ["initial", "initial_spawn", "steps", "phases"])

    hints
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case normalize_model_routing_step_hints_key(key) do
        :initial -> Map.put_new(acc, :initial, value)
        :initial_spawn -> Map.put(acc, :initial, value)
        nil -> acc
        normalized -> Map.put(acc, normalized, value)
      end
    end)
  end

  defp normalize_model_routing_step_hints(_hints, _section_name), do: :omit

  defp normalize_model_routing_step_hints_key(value) when value in ["initial", :initial], do: :initial
  defp normalize_model_routing_step_hints_key(value) when value in ["initial_spawn", :initial_spawn], do: :initial_spawn
  defp normalize_model_routing_step_hints_key(value) when value in ["steps", :steps], do: :steps
  defp normalize_model_routing_step_hints_key(value) when value in ["phases", :phases], do: :phases
  defp normalize_model_routing_step_hints_key(_value), do: nil

  defp normalize_model_routing_candidates(candidates, section_name) when is_list(candidates) do
    Enum.with_index(candidates)
    |> Enum.map(fn
      {candidate, index} when is_map(candidate) -> normalize_model_routing_map(candidate, "#{section_name}.#{index}")
      {_candidate, _index} -> %{}
    end)
  end

  defp normalize_model_routing_candidates(_candidates, _section_name), do: []

  defp normalize_model_routing_profiles(profiles) when is_map(profiles) do
    profiles
    |> Enum.reduce(%{}, fn {name, profile}, acc ->
      normalized = normalize_model_routing_profile(profile, "model_routing.profiles.#{normalize_key(name)}")
      if map_size(normalized) > 0, do: Map.put(acc, to_string(name), normalized), else: acc
    end)
    |> case do
      normalized when map_size(normalized) > 0 -> normalized
      _empty -> :omit
    end
  end

  defp normalize_model_routing_profiles(_profiles), do: :omit

  defp normalize_model_routing_profile(profile, section_name) when is_map(profile) do
    profile = warn_unknown_config_keys(section_name, profile, ["tier", "model", "mode", "adapter", "required", "candidates"])

    %{}
    |> put_if_present(:tier, normalize_tier_key(map_value(profile, :tier)))
    |> put_if_present(:model, normalize_profile_string(map_value(profile, :model)))
    |> put_if_present(:mode, normalize_profile_mode(map_value(profile, :mode)))
    |> put_if_present(:adapter, normalize_profile_string(map_value(profile, :adapter)))
    |> put_if_present(:required, normalize_profile_required(map_value(profile, :required)))
    |> put_if_present(:candidates, normalize_model_routing_profile_candidates(map_value(profile, :candidates), "#{section_name}.candidates"))
  end

  defp normalize_model_routing_profile(_profile, _section_name), do: %{}

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp normalize_profile_string(nil), do: :omit
  defp normalize_profile_string(value) when is_binary(value), do: value
  defp normalize_profile_string(_value), do: :omit

  defp normalize_profile_mode("prefer"), do: "prefer"
  defp normalize_profile_mode(:prefer), do: "prefer"
  defp normalize_profile_mode("require"), do: "require"
  defp normalize_profile_mode(:require), do: "require"
  defp normalize_profile_mode(_mode), do: :omit

  defp normalize_profile_required(value) when is_boolean(value), do: value
  defp normalize_profile_required(_value), do: :omit

  defp normalize_model_routing_profile_candidates(candidates, section_name) when is_list(candidates) do
    Enum.with_index(candidates)
    |> Enum.map(fn
      {candidate, index} when is_map(candidate) -> normalize_model_routing_map(candidate, "#{section_name}.#{index}")
      {_candidate, _index} -> %{}
    end)
  end

  defp normalize_model_routing_profile_candidates(_candidates, _section_name), do: :omit

  defp normalize_model_routing_map(map, section_name) when is_map(map) do
    map = warn_unknown_config_keys(section_name, map, ["adapter", "agent_adapter", "model", "tier", "mode", "required"])

    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case normalize_model_routing_key(key) do
        nil -> acc
        normalized -> Map.put(acc, normalized, value)
      end
    end)
  end

  defp normalize_model_routing_map(_map, _section_name), do: :omit

  defp normalize_tier_key(value) when value in ["light", :light], do: :light
  defp normalize_tier_key(value) when value in ["standard", :standard], do: :standard
  defp normalize_tier_key(value) when value in ["heavy", :heavy], do: :heavy
  defp normalize_tier_key(value) when value in ["frontier", :frontier], do: :frontier
  defp normalize_tier_key(_value), do: nil

  defp normalize_model_routing_key(value) when value in ["adapter", :adapter], do: :adapter
  defp normalize_model_routing_key(value) when value in ["agent_adapter", :agent_adapter], do: :agent_adapter
  defp normalize_model_routing_key(value) when value in ["model", :model], do: :model
  defp normalize_model_routing_key(value) when value in ["tier", :tier], do: :tier
  defp normalize_model_routing_key(value) when value in ["mode", :mode], do: :mode
  defp normalize_model_routing_key(value) when value in ["required", :required], do: :required
  defp normalize_model_routing_key(_value), do: nil

  defp tools_list_value(values) when is_list(values) do
    filtered = Enum.filter(values, &is_binary/1) |> Enum.reject(&(String.trim(&1) == ""))
    if filtered == [], do: :omit, else: filtered
  end

  defp tools_list_value(_value), do: :omit

  defp tier_list_value(values) when is_list(values) do
    normalized =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if normalized == [], do: :omit, else: normalized
  end

  defp tier_list_value(_value), do: :omit

  defp worker_hosts_value(values, section_name) when is_list(values) do
    Enum.with_index(values)
    |> Enum.map(fn
      {host, index} when is_map(host) -> worker_host_value(host, "#{section_name}.#{index}")
      {_host, _index} -> %{}
    end)
  end

  defp worker_hosts_value(_value, _section_name), do: :omit

  defp worker_host_value(host, section_name) when is_map(host) do
    host = warn_unknown_config_keys(section_name, host, ["name", "host", "user", "port", "max_concurrent_agents"])

    %{}
    |> put_if_present(:name, scalar_string_value(Map.get(host, "name")))
    |> put_if_present(:host, scalar_string_value(Map.get(host, "host")))
    |> put_if_present(:user, scalar_string_value(Map.get(host, "user")))
    |> put_if_present(:port, positive_integer_value(Map.get(host, "port")))
    |> put_if_present(
      :max_concurrent_agents,
      positive_integer_value(Map.get(host, "max_concurrent_agents"))
    )
  end

  defp extract_hooks_options(section) do
    section = warn_unknown_config_keys("hooks", section, ["after_create", "before_run", "after_run", "before_remove", "timeout_ms"])

    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
  end

  defp extract_gates_options(gates, section_name) when is_list(gates) do
    Enum.with_index(gates)
    |> Enum.map(fn
      {gate, index} when is_map(gate) ->
        gate = warn_unknown_config_keys("#{section_name}.#{index}", gate, ["name", "command", "timeout_ms", "action_id", "action_classes"])

        %{}
        |> put_if_present(:name, scalar_string_value(Map.get(gate, "name")))
        |> put_if_present(:command, command_value(Map.get(gate, "command")))
        |> put_if_present(:timeout_ms, positive_integer_value(Map.get(gate, "timeout_ms")))
        |> put_if_present(:action_id, scalar_string_value(Map.get(gate, "action_id")))
        |> put_if_present(:action_classes, tools_list_value(Map.get(gate, "action_classes")))

      {_gate, _index} ->
        %{}
    end)
  end

  defp extract_gates_options(_gates, _section_name), do: []

  defp extract_gate_reuse_options(section) do
    section = warn_unknown_config_keys("gate_reuse", section, ["enabled"])

    %{}
    |> put_if_present(:enabled, boolean_value(Map.get(section, "enabled")))
  end

  defp extract_clean_eval_options(section) do
    section = warn_unknown_config_keys("clean_eval", section, ["enabled", "base_ref", "gates"])

    %{}
    |> put_if_present(:enabled, boolean_value(Map.get(section, "enabled")))
    |> put_if_present(:base_ref, scalar_string_value(Map.get(section, "base_ref")))
    |> put_if_present(:gates, clean_eval_gates_value(Map.get(section, "gates")))
  end

  defp clean_eval_gates_value(gates) when is_list(gates), do: extract_gates_options(gates, "clean_eval.gates")
  defp clean_eval_gates_value(_gates), do: :omit

  defp extract_observability_options(section) do
    section = warn_unknown_config_keys("observability", section, ["dashboard_enabled", "refresh_ms", "render_interval_ms"])

    %{}
    |> put_if_present(:dashboard_enabled, boolean_value(Map.get(section, "dashboard_enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
  end

  defp extract_server_options(section) do
    section = warn_unknown_config_keys("server", section, ["port", "host"])

    %{}
    |> put_if_present(:port, non_negative_integer_value(Map.get(section, "port")))
    |> put_if_present(:host, scalar_string_value(Map.get(section, "host")))
  end

  defp workflow_default_options do
    %{}
    |> extract_workflow_options()
    |> NimbleOptions.validate!(@workflow_options_schema)
  end

  defp log_workflow_load_failure(reason) do
    Logger.error("WORKFLOW.md load failed; defaults are being used reason=#{inspect(reason)}")
  end

  defp warn_unknown_config_keys(section_name, section, allowed_keys) when is_map(section) do
    allowed_keys = allowed_keys |> Enum.map(&normalize_key/1) |> MapSet.new()

    section
    |> Map.keys()
    |> Enum.map(&normalize_key/1)
    |> Enum.reject(&MapSet.member?(allowed_keys, &1))
    |> Enum.each(fn key ->
      Logger.warning("unknown config key section=#{section_name} key=#{key}")
    end)

    section
  end

  defp validate_raw_config(config) do
    tracker = section_map(config, "tracker")
    polling = section_map(config, "polling")
    workspace = section_map(config, "workspace")
    worker = section_map(config, "worker")
    agent = section_map(config, "agent")
    claude = section_map(config, "claude")
    pi = section_map(config, "pi")
    codex = section_map(config, "codex")
    action_policy = section_map(config, "action_policy")
    release_loop = section_map(config, "release_loop")
    release_loop_review_policy = section_map(release_loop, "review_policy")
    release_loop_closeout = section_map(release_loop, "closeout")
    release_loop_merge = section_map(release_loop_closeout, "merge")
    process_provider = section_map(config, "process_provider")
    escalation = section_map(config, "escalation")
    hooks = section_map(config, "hooks")
    gates = Map.get(config, "gates")
    gate_reuse = section_map(config, "gate_reuse")
    clean_eval = section_map(config, "clean_eval")
    observability = section_map(config, "observability")
    server = section_map(config, "server")

    [
      validate_section_map(config, "tracker"),
      validate_section_map(config, "polling"),
      validate_section_map(config, "workspace"),
      validate_section_map(config, "worker"),
      validate_section_map(config, "agent"),
      validate_section_map(config, "claude"),
      validate_section_map(config, "pi"),
      validate_section_map(config, "codex"),
      validate_section_map(config, "action_policy"),
      validate_section_map(config, "release_loop"),
      validate_section_map(release_loop, "review_policy"),
      validate_section_map(release_loop, "closeout"),
      validate_section_map(release_loop_closeout, "merge"),
      validate_section_map(config, "process_provider"),
      validate_section_map(config, "model_routing"),
      validate_section_map(config, "escalation"),
      validate_boolean_field(escalation, "escalation.enabled"),
      validate_tier_list_field(escalation, "escalation.tiers"),
      validate_positive_integer_field(escalation, "escalation.max_total_attempts"),
      validate_positive_integer_field(escalation, "escalation.token_budget"),
      validate_positive_integer_field(escalation, "escalation.report_repair_attempts"),
      validate_section_map(config, "hooks"),
      validate_gates_field(gates),
      validate_section_map(config, "gate_reuse"),
      validate_boolean_field(gate_reuse, "gate_reuse.enabled"),
      validate_section_map(config, "clean_eval"),
      validate_boolean_field(clean_eval, "clean_eval.enabled"),
      validate_string_field(clean_eval, "clean_eval.base_ref"),
      validate_clean_eval_gates_field(clean_eval),
      validate_section_map(config, "observability"),
      validate_section_map(config, "server"),
      validate_string_field(tracker, "tracker.kind"),
      validate_string_field(tracker, "tracker.endpoint"),
      validate_string_field(tracker, "tracker.api_key", allow_empty: true),
      validate_string_field(tracker, "tracker.project_slug"),
      validate_string_field(tracker, "tracker.repo"),
      validate_string_field(tracker, "tracker.state_label_prefix"),
      validate_string_field(tracker, "tracker.assignee"),
      validate_non_empty_string_or_string_list_field(tracker, "tracker.active_states"),
      validate_non_empty_string_or_string_list_field(tracker, "tracker.review_states"),
      validate_non_empty_string_or_string_list_field(tracker, "tracker.terminal_states"),
      validate_string_or_string_list_field(tracker, "tracker.label_filter"),
      validate_positive_integer_field(polling, "polling.interval_ms"),
      validate_string_field(workspace, "workspace.root"),
      validate_positive_integer_field(worker, "worker.max_concurrent_agents_per_host"),
      validate_worker_ssh_hosts_field(worker),
      validate_positive_integer_field(agent, "agent.max_concurrent_agents"),
      validate_non_empty_string_field(agent, "agent.adapter"),
      validate_positive_integer_field(agent, "agent.max_turns"),
      validate_positive_integer_field(agent, "agent.max_retry_backoff_ms"),
      validate_state_limits_field(agent, "agent.max_concurrent_agents_by_state"),
      validate_string_field(claude, "claude.command", allow_empty: true),
      validate_inclusion_field(claude, "claude.permission_mode", @valid_claude_permission_modes),
      validate_boolean_field(claude, "claude.dangerously_skip_permissions"),
      validate_positive_integer_field(claude, "claude.max_turns"),
      validate_inclusion_field(claude, "claude.output_format", ["stream-json"]),
      validate_string_field(claude, "claude.model"),
      validate_optional_string_list_field(claude, "claude.allowed_tools"),
      validate_positive_integer_field(claude, "claude.turn_timeout_ms"),
      validate_positive_integer_field(claude, "claude.stall_timeout_ms"),
      validate_string_field(pi, "pi.command", allow_empty: true),
      validate_positive_integer_field(pi, "pi.turn_timeout_ms"),
      validate_positive_integer_field(pi, "pi.stall_timeout_ms"),
      validate_string_field(codex, "codex.command", allow_empty: true),
      validate_positive_integer_field(codex, "codex.turn_timeout_ms"),
      validate_positive_integer_field(codex, "codex.stall_timeout_ms"),
      validate_string_field(action_policy, "action_policy.command"),
      validate_inclusion_field(action_policy, "action_policy.run_mode", @valid_action_policy_run_modes),
      validate_existing_file_field(action_policy, "action_policy.policy_file"),
      validate_boolean_field(release_loop, "release_loop.enabled"),
      validate_string_field(release_loop, "release_loop.pr_review_source"),
      validate_string_field(release_loop, "release_loop.pr_review_update"),
      validate_positive_integer_field(release_loop, "release_loop.wait_interval_seconds"),
      validate_boolean_field(release_loop, "release_loop.run_configured_gates_before_push"),
      validate_inclusion_field(release_loop, "release_loop.max_pr_risk_level", @valid_release_loop_pr_risk_levels),
      validate_string_or_string_list_field(release_loop_review_policy, "release_loop.review_policy.high_risk_paths"),
      validate_string_or_string_list_field(release_loop_review_policy, "release_loop.review_policy.low_risk_paths"),
      validate_positive_integer_field(release_loop_review_policy, "release_loop.review_policy.high_risk_file_count"),
      validate_positive_integer_field(release_loop_review_policy, "release_loop.review_policy.high_risk_total_changes"),
      validate_positive_integer_field(release_loop_review_policy, "release_loop.review_policy.low_risk_file_count"),
      validate_positive_integer_field(release_loop_review_policy, "release_loop.review_policy.low_risk_total_changes"),
      validate_string_field(release_loop, "release_loop.review_state"),
      validate_string_field(release_loop, "release_loop.rework_state"),
      validate_string_field(release_loop, "release_loop.merge_state"),
      validate_string_field(release_loop, "release_loop.done_state"),
      validate_inclusion_field(release_loop_merge, "release_loop.closeout.merge.mode", ["auto", "ask", "deny"]),
      validate_inclusion_field(release_loop_merge, "release_loop.closeout.merge.method", ["merge", "squash", "rebase"]),
      validate_boolean_field(release_loop_merge, "release_loop.closeout.merge.delete_branch"),
      validate_inclusion_field(process_provider, "process_provider.kind", @valid_process_provider_kinds),
      validate_boolean_field(process_provider, "process_provider.required"),
      validate_string_field(process_provider, "process_provider.artifact_path"),
      validate_string_field(hooks, "hooks.after_create"),
      validate_string_field(hooks, "hooks.before_run"),
      validate_string_field(hooks, "hooks.after_run"),
      validate_string_field(hooks, "hooks.before_remove"),
      validate_positive_integer_field(hooks, "hooks.timeout_ms"),
      validate_boolean_field(observability, "observability.dashboard_enabled"),
      validate_positive_integer_field(observability, "observability.refresh_ms"),
      validate_positive_integer_field(observability, "observability.render_interval_ms"),
      validate_non_negative_integer_field(server, "server.port"),
      validate_string_field(server, "server.host")
    ]
    |> List.flatten()
  end

  defp validate_section_map(config, section) do
    case Map.fetch(config, section) do
      {:ok, nil} -> []
      {:ok, value} when is_map(value) -> []
      {:ok, value} -> [config_error(section, value, "must be a map")]
      :error -> []
    end
  end

  defp validate_string_field(section, path, opts \\ []) do
    validate_present_value(section, path, fn value ->
      allow_empty = Keyword.get(opts, :allow_empty, false)

      cond do
        is_binary(value) and (allow_empty or String.trim(value) != "") ->
          []

        is_binary(value) ->
          [config_error(path, value, "must be a non-empty string")]

        true ->
          [config_error(path, value, "must be a string")]
      end
    end)
  end

  defp validate_non_empty_string_field(section, path), do: validate_string_field(section, path)

  defp validate_string_or_string_list_field(section, path) do
    validate_present_value(section, path, fn
      value when is_binary(value) ->
        []

      values when is_list(values) ->
        invalid? = Enum.any?(values, fn value -> not is_binary(value) end)
        if invalid?, do: [config_error(path, values, "must be a string or list of strings")], else: []

      value ->
        [config_error(path, value, "must be a string or list of strings")]
    end)
  end

  defp validate_non_empty_string_or_string_list_field(section, path) do
    validate_present_value(section, path, fn
      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> [config_error(path, value, "must include at least one non-empty value")]
          _values -> []
        end

      values when is_list(values) ->
        normalized_values =
          values
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        cond do
          Enum.any?(values, fn value -> not is_binary(value) end) ->
            [config_error(path, values, "must be a string or list of strings")]

          normalized_values == [] ->
            [config_error(path, values, "must include at least one non-empty value")]

          true ->
            []
        end

      value ->
        [config_error(path, value, "must be a string or list of strings")]
    end)
  end

  defp validate_optional_string_list_field(section, path) do
    validate_present_value(section, path, fn
      values when is_list(values) ->
        invalid? = Enum.any?(values, fn value -> not is_binary(value) or String.trim(value) == "" end)
        if invalid?, do: [config_error(path, values, "must be a list of non-empty strings")], else: []

      value ->
        [config_error(path, value, "must be a list of non-empty strings")]
    end)
  end

  defp validate_existing_file_field(section, path) do
    validate_present_value(section, path, fn
      value when is_binary(value) ->
        expanded = value |> String.trim() |> Path.expand()

        case File.stat(expanded) do
          {:ok, %File.Stat{type: :regular, access: access}} when access in [:read, :read_write] ->
            []

          _ ->
            [config_error(path, value, "must reference an existing readable file")]
        end

      value ->
        [config_error(path, value, "must be a string path to an existing file")]
    end)
  end

  defp validate_inclusion_field(section, path, valid_values) do
    validate_present_value(section, path, fn
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed in valid_values do
          []
        else
          [config_error(path, value, "must be one of #{Enum.join(valid_values, ", ")}")]
        end

      value ->
        [config_error(path, value, "must be one of #{Enum.join(valid_values, ", ")}")]
    end)
  end

  defp validate_boolean_field(section, path) do
    validate_present_value(section, path, fn
      value when is_boolean(value) ->
        []

      value when is_binary(value) ->
        case String.downcase(String.trim(value)) do
          "true" -> []
          "false" -> []
          _ -> [config_error(path, value, "must be true or false")]
        end

      value ->
        [config_error(path, value, "must be true or false")]
    end)
  end

  defp validate_positive_integer_field(section, path) do
    validate_integer_field(section, path, &(&1 > 0), "must be a positive integer")
  end

  defp validate_non_negative_integer_field(section, path) do
    validate_integer_field(section, path, &(&1 >= 0), "must be a non-negative integer")
  end

  defp validate_integer_field(section, path, predicate, message) do
    validate_present_value(section, path, fn value ->
      validate_integer_value(value, path, predicate, message)
    end)
  end

  defp validate_integer_value(value, path, predicate, message) do
    case parse_integer(value) do
      {:ok, parsed} -> validate_integer_predicate(parsed, value, path, predicate, message)
      :error -> [config_error(path, value, message)]
    end
  end

  defp validate_integer_predicate(parsed, value, path, predicate, message) do
    if predicate.(parsed), do: [], else: [config_error(path, value, message)]
  end

  defp validate_state_limits_field(section, path) do
    validate_present_value(section, path, fn
      value when is_map(value) -> Enum.flat_map(value, &validate_state_limit_entry(&1, path))
      value -> [config_error(path, value, "must be a map of state names to positive integers")]
    end)
  end

  defp validate_state_limit_entry({state_name, limit}, path) do
    normalized_state = normalize_issue_state(to_string(state_name))

    case normalized_state do
      "" -> [config_error(path, state_name, "state name must be non-empty")]
      state -> validate_state_limit_value(limit, path <> "." <> state)
    end
  end

  defp validate_state_limit_value(limit, entry_path) do
    case parse_integer(limit) do
      {:ok, parsed} when parsed > 0 -> []
      _ -> [config_error(entry_path, limit, "must be a positive integer")]
    end
  end

  defp validate_tier_list_field(section, path) do
    validate_present_value(section, path, fn
      values when is_list(values) ->
        invalid = Enum.reject(values, fn value -> is_binary(value) and String.trim(value) in ["light", "standard", "heavy", "frontier"] end)

        cond do
          Enum.any?(values, fn value -> not is_binary(value) end) ->
            [config_error(path, values, "must be a list of tier strings")]

          invalid != [] ->
            [config_error(path, invalid, "must be one of light, standard, heavy, frontier")]

          true ->
            []
        end

      value ->
        [config_error(path, value, "must be a list of tier strings")]
    end)
  end

  defp validate_clean_eval_gates_field(clean_eval) do
    case Map.fetch(clean_eval, "gates") do
      {:ok, gates} -> validate_gates_field(gates, "clean_eval.gates")
      :error -> []
    end
  end

  defp validate_worker_ssh_hosts_field(worker) do
    case Map.fetch(worker, "ssh_hosts") do
      {:ok, hosts} -> validate_worker_host_list(hosts, "worker.ssh_hosts")
      :error -> []
    end
  end

  defp validate_worker_host_list(nil, _field_path), do: []

  defp validate_worker_host_list(hosts, field_path) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.flat_map(fn {host, index} -> validate_worker_host_entry(host, index, field_path) end)
  end

  defp validate_worker_host_list(hosts, field_path), do: [config_error(field_path, hosts, "must be a list of host maps")]

  defp validate_worker_host_entry(host, index, field_path) when is_map(host) do
    path = "#{field_path}.#{index}"

    [
      validate_required_string_field(host, "#{path}.host", "host"),
      validate_optional_string_field(host, "#{path}.name", "name"),
      validate_optional_string_field(host, "#{path}.user", "user"),
      validate_optional_positive_integer_field(host, "#{path}.port", "port"),
      validate_optional_positive_integer_field(host, "#{path}.max_concurrent_agents", "max_concurrent_agents")
    ]
    |> List.flatten()
  end

  defp validate_worker_host_entry(host, index, field_path), do: [config_error("#{field_path}.#{index}", host, "must be a map")]

  defp validate_optional_string_field(section, path, _key) do
    validate_present_value(section, path, fn value ->
      cond do
        is_binary(value) and String.trim(value) != "" -> []
        is_binary(value) -> [config_error(path, value, "must be a non-empty string")]
        true -> [config_error(path, value, "must be a string")]
      end
    end)
  end

  defp validate_optional_positive_integer_field(section, path, _key) do
    validate_present_value(section, path, fn value ->
      case parse_integer(value) do
        {:ok, parsed} when parsed > 0 -> []
        _ -> [config_error(path, value, "must be a positive integer")]
      end
    end)
  end

  defp validate_gates_field(gates, field_path \\ "gates")

  defp validate_gates_field(nil, _field_path), do: []

  defp validate_gates_field(gates, field_path) when is_list(gates) do
    gates
    |> Enum.with_index()
    |> Enum.flat_map(fn {gate, index} -> validate_gate_entry(gate, index, field_path) end)
  end

  defp validate_gates_field(gates, field_path), do: [config_error(field_path, gates, "must be a list of gate maps")]

  defp validate_gate_entry(gate, index, field_path) when is_map(gate) do
    path = "#{field_path}.#{index}"

    [
      validate_required_string_field(gate, "#{path}.name", "name"),
      validate_required_string_field(gate, "#{path}.command", "command"),
      validate_gate_timeout_field(gate, path),
      validate_optional_gate_action_id_field(gate, path),
      validate_optional_gate_action_classes_field(gate, path)
    ]
    |> List.flatten()
  end

  defp validate_gate_entry(gate, index, field_path), do: [config_error("#{field_path}.#{index}", gate, "must be a map")]

  defp validate_required_string_field(section, path, key) do
    case Map.fetch(section, key) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          [config_error(path, value, "must be a non-empty string")]
        else
          []
        end

      {:ok, value} ->
        [config_error(path, value, "must be a string")]

      :error ->
        [config_error(path, nil, "is required")]
    end
  end

  defp validate_gate_timeout_field(gate, path) do
    validate_present_value(gate, "#{path}.timeout_ms", fn value ->
      validate_integer_value(value, "#{path}.timeout_ms", &(&1 > 0), "must be a positive integer")
    end)
  end

  defp validate_optional_gate_action_id_field(gate, path) do
    validate_present_value(gate, "#{path}.action_id", fn
      value when is_binary(value) ->
        if String.trim(value) == "", do: [config_error("#{path}.action_id", value, "must be a non-empty string")], else: []

      value ->
        [config_error("#{path}.action_id", value, "must be a string")]
    end)
  end

  defp validate_optional_gate_action_classes_field(gate, path) do
    validate_present_value(gate, "#{path}.action_classes", fn
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          []
        else
          [config_error("#{path}.action_classes", values, "must be a non-empty list of non-empty strings")]
        end

      value ->
        [config_error("#{path}.action_classes", value, "must be a non-empty list of non-empty strings")]
    end)
  end

  defp validate_present_value(section, path, validator) do
    key = path |> String.split(".") |> List.last()

    case Map.fetch(section, key) do
      {:ok, nil} -> []
      {:ok, value} -> validator.(value)
      :error -> []
    end
  end

  defp invalid_workflow_config(path, errors), do: {:invalid_workflow_config, path, errors}

  defp config_error(path, value, message) do
    %{path: path, value: value, message: message}
  end

  defp nimble_error(%NimbleOptions.ValidationError{} = error) do
    keys_path = error |> Map.from_struct() |> Map.get(:keys_path, [])
    config_error(Enum.join(keys_path || [], "."), nil, Exception.message(error))
  end

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp put_if_present(map, _key, :omit), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp binary_value(value, opts \\ [])

  defp binary_value(value, opts) when is_binary(value) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if value == "" and not allow_empty do
      :omit
    else
      value
    end
  end

  defp binary_value(_value, _opts), do: :omit

  defp command_value(value) when is_binary(value), do: String.trim(value)

  defp command_value(_value), do: :omit

  defp hook_command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      _ -> String.trim_trailing(value)
    end
  end

  defp hook_command_value(_value), do: :omit

  defp label_filter_value(values) when is_list(values) do
    filtered =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if filtered == [], do: :omit, else: filtered
  end

  defp label_filter_value(value) when is_binary(value), do: csv_value(value)
  defp label_filter_value(_), do: :omit

  defp csv_value(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, acc -> maybe_append_csv_value(acc, value) end)
    |> Enum.reverse()
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(_value), do: :omit

  defp maybe_append_csv_value(acc, value) do
    case scalar_string_value(value) do
      :omit ->
        acc

      normalized ->
        append_csv_value_if_present(acc, normalized)
    end
  end

  defp append_csv_value_if_present(acc, value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      [trimmed | acc]
    end
  end

  defp integer_value(value) do
    case parse_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp positive_integer_value(value) do
    case parse_positive_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp non_negative_integer_value(value) do
    case parse_non_negative_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp boolean_value(_value), do: :omit

  defp state_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), parsed)

        :error ->
          acc
      end
    end)
  end

  defp state_limits_value(_value), do: :omit

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, rest} ->
        if String.trim(rest) == "", do: {:ok, parsed}, else: :error

      :error ->
        :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_non_negative_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_path_value(:missing, default), do: default
  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name()
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp preserve_command_name(path) do
    cond do
      uri_path?(path) ->
        path

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        Path.expand(path)

      true ->
        path
    end
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp resolve_secret_env_value(:missing, fallback), do: fallback
  defp resolve_secret_env_value(nil, fallback), do: fallback

  defp resolve_secret_env_value(value, _fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> nil
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_secret_env_value(_value, fallback), do: fallback

  defp resolve_env_value(:missing, fallback), do: fallback
  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret_value(_value), do: nil
end
