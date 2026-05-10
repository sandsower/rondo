defmodule Rondo.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias NimbleOptions
  alias Rondo.Workflow

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
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
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
  @default_debug false
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_server_host "127.0.0.1"
  @workflow_options_schema NimbleOptions.new!(
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: {:or, [:string, nil]}, default: nil],
                                 endpoint: [type: :string, default: @default_linear_endpoint],
                                 api_key: [type: {:or, [:string, nil]}, default: nil],
                                 project_slug: [type: {:or, [:string, nil]}, default: nil],
                                 assignee: [type: {:or, [:string, nil]}, default: nil],
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
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
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
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
                                 dangerously_skip_permissions: [type: :boolean, default: @default_claude_dangerously_skip_permissions],
                                 max_turns: [type: :pos_integer, default: @default_claude_max_turns],
                                 output_format: [type: :string, default: @default_claude_output_format],
                                 model: [type: {:or, [:string, nil]}, default: nil],
                                 allowed_tools: [type: {:or, [{:list, :string}, nil]}, default: nil],
                                 turn_timeout_ms: [type: :integer, default: @default_claude_turn_timeout_ms],
                                 stall_timeout_ms: [type: :integer, default: @default_claude_stall_timeout_ms]
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

  @spec linear_active_states() :: [String.t()]
  def linear_active_states do
    get_in(validated_workflow_options(), [:tracker, :active_states])
  end

  @spec linear_terminal_states() :: [String.t()]
  def linear_terminal_states do
    get_in(validated_workflow_options(), [:tracker, :terminal_states])
  end

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

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
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

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
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
         :ok <- require_linear_project(options, path) do
      require_claude_command(options, path)
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

  defp require_claude_command(options) do
    case get_in(options, [:claude, :command]) do
      command when is_binary(command) ->
        if byte_size(String.trim(command)) > 0 do
          :ok
        else
          {:error, :missing_claude_command}
        end

      _ ->
        {:error, :missing_claude_command}
    end
  end

  defp require_tracker_kind(options, path) do
    case require_tracker_kind(options) do
      :ok -> :ok
      {:error, :missing_tracker_kind} -> {:error, invalid_workflow_config(path, [config_error("tracker.kind", nil, "is required")])}
      {:error, {:unsupported_tracker_kind, kind}} -> {:error, invalid_workflow_config(path, [config_error("tracker.kind", kind, "must be linear or memory")])}
    end
  end

  defp require_linear_token(options, path) do
    case require_linear_token(options) do
      :ok -> :ok
      {:error, :missing_linear_api_token} -> {:error, invalid_workflow_config(path, [config_error("tracker.api_key", nil, "is required for linear tracker")])}
    end
  end

  defp require_linear_project(options, path) do
    case require_linear_project(options) do
      :ok -> :ok
      {:error, :missing_linear_project_slug} -> {:error, invalid_workflow_config(path, [config_error("tracker.project_slug", nil, "is required for linear tracker")])}
    end
  end

  defp require_claude_command(options, path) do
    case require_claude_command(options) do
      :ok -> :ok
      {:error, :missing_claude_command} -> {:error, invalid_workflow_config(path, [config_error("claude.command", nil, "is required")])}
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

      _ ->
        %{}
        |> extract_workflow_options()
        |> NimbleOptions.validate!(@workflow_options_schema)
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
          {:ok, options} -> {:ok, options}
          {:error, %NimbleOptions.ValidationError{} = error} -> {:error, invalid_workflow_config(path, [nimble_error(error)])}
        end

      errors ->
        {:error, invalid_workflow_config(path, errors)}
    end
  end

  defp validate_workflow_options(_workflow, path) do
    {:error, invalid_workflow_config(path, [config_error("workflow", nil, "must include a config map")])}
  end

  defp extract_workflow_options(config) do
    %{
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      agent: extract_agent_options(section_map(config, "agent")),
      claude: extract_claude_options(section_map(config, "claude")),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      observability: extract_observability_options(section_map(config, "observability")),
      server: extract_server_options(section_map(config, "server"))
    }
  end

  defp extract_tracker_options(section) do
    %{}
    |> put_if_present(:kind, normalize_tracker_kind(scalar_string_value(Map.get(section, "kind"))))
    |> put_if_present(:endpoint, scalar_string_value(Map.get(section, "endpoint")))
    |> put_if_present(:api_key, binary_value(Map.get(section, "api_key"), allow_empty: true))
    |> put_if_present(:project_slug, scalar_string_value(Map.get(section, "project_slug")))
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
    |> put_if_present(:label_filter, label_filter_value(Map.get(section, "label_filter")))
  end

  defp extract_polling_options(section) do
    %{}
    |> put_if_present(:interval_ms, integer_value(Map.get(section, "interval_ms")))
  end

  defp extract_workspace_options(section) do
    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_agent_options(section) do
    %{}
    |> put_if_present(:max_concurrent_agents, integer_value(Map.get(section, "max_concurrent_agents")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:max_retry_backoff_ms, positive_integer_value(Map.get(section, "max_retry_backoff_ms")))
    |> put_if_present(
      :max_concurrent_agents_by_state,
      state_limits_value(Map.get(section, "max_concurrent_agents_by_state"))
    )
  end

  defp extract_claude_options(section) do
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

  defp tools_list_value(values) when is_list(values) do
    filtered = Enum.filter(values, &is_binary/1) |> Enum.reject(&(String.trim(&1) == ""))
    if filtered == [], do: :omit, else: filtered
  end

  defp tools_list_value(_value), do: :omit

  defp extract_hooks_options(section) do
    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
  end

  defp extract_observability_options(section) do
    %{}
    |> put_if_present(:dashboard_enabled, boolean_value(Map.get(section, "dashboard_enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
  end

  defp extract_server_options(section) do
    %{}
    |> put_if_present(:port, non_negative_integer_value(Map.get(section, "port")))
    |> put_if_present(:host, scalar_string_value(Map.get(section, "host")))
  end

  defp validate_raw_config(config) do
    tracker = section_map(config, "tracker")
    polling = section_map(config, "polling")
    workspace = section_map(config, "workspace")
    agent = section_map(config, "agent")
    claude = section_map(config, "claude")
    hooks = section_map(config, "hooks")
    observability = section_map(config, "observability")
    server = section_map(config, "server")

    [
      validate_section_map(config, "tracker"),
      validate_section_map(config, "polling"),
      validate_section_map(config, "workspace"),
      validate_section_map(config, "agent"),
      validate_section_map(config, "claude"),
      validate_section_map(config, "hooks"),
      validate_section_map(config, "observability"),
      validate_section_map(config, "server"),
      validate_string_field(tracker, "tracker.kind"),
      validate_string_field(tracker, "tracker.endpoint"),
      validate_string_field(tracker, "tracker.api_key", allow_empty: true),
      validate_string_field(tracker, "tracker.project_slug"),
      validate_string_field(tracker, "tracker.assignee"),
      validate_non_empty_string_or_string_list_field(tracker, "tracker.active_states"),
      validate_non_empty_string_or_string_list_field(tracker, "tracker.terminal_states"),
      validate_string_or_string_list_field(tracker, "tracker.label_filter"),
      validate_positive_integer_field(polling, "polling.interval_ms"),
      validate_string_field(workspace, "workspace.root"),
      validate_positive_integer_field(agent, "agent.max_concurrent_agents"),
      validate_positive_integer_field(agent, "agent.max_turns"),
      validate_positive_integer_field(agent, "agent.max_retry_backoff_ms"),
      validate_state_limits_field(agent, "agent.max_concurrent_agents_by_state"),
      validate_non_empty_string_field(claude, "claude.command"),
      validate_inclusion_field(claude, "claude.permission_mode", @valid_claude_permission_modes),
      validate_boolean_field(claude, "claude.dangerously_skip_permissions"),
      validate_positive_integer_field(claude, "claude.max_turns"),
      validate_inclusion_field(claude, "claude.output_format", ["stream-json"]),
      validate_string_field(claude, "claude.model"),
      validate_optional_string_list_field(claude, "claude.allowed_tools"),
      validate_positive_integer_field(claude, "claude.turn_timeout_ms"),
      validate_positive_integer_field(claude, "claude.stall_timeout_ms"),
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
      case parse_integer(value) do
        {:ok, parsed} ->
          if predicate.(parsed), do: [], else: [config_error(path, value, message)]

        :error ->
          [config_error(path, value, message)]
      end
    end)
  end

  defp validate_state_limits_field(section, path) do
    validate_present_value(section, path, fn
      value when is_map(value) ->
        value
        |> Enum.flat_map(fn {state_name, limit} ->
          normalized_state = normalize_issue_state(to_string(state_name))

          if normalized_state == "" do
            [config_error(path, state_name, "state name must be non-empty")]
          else
            entry_path = path <> "." <> normalized_state

            case parse_integer(limit) do
              {:ok, parsed} when parsed > 0 -> []
              _ -> [config_error(entry_path, limit, "must be a positive integer")]
            end
          end
        end)

      value ->
        [config_error(path, value, "must be a map of state names to positive integers")]
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

  defp command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

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
