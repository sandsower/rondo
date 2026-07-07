defmodule Rondo.Agent.Env do
  @moduledoc """
  Environment controls for child agent subprocesses.

  Rondo agents run on untrusted ticket and review text, so child processes must
  not inherit tracker, repository, deployment, or shell auth tokens by default.
  Provider-specific CLI authentication can still be supplied by that provider's
  own config, but broad ambient secrets are scrubbed at the spawn boundary.
  """

  @default_sensitive_keys ~w(
    LINEAR_API_KEY
    LINEAR_TOKEN
    GITHUB_TOKEN
    GH_TOKEN
    GIT_ASKPASS
    GIT_SSH
    GIT_SSH_COMMAND
    SSH_AGENT_PID
    SSH_AUTH_SOCK
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
    GOOGLE_APPLICATION_CREDENTIALS
    GCLOUD_PROJECT
    GCP_PROJECT
  )

  @doc "Returns Port.open/2 environment overrides that unset ambient secrets."
  @spec port_env(keyword(), [{charlist(), charlist() | false}]) :: [{charlist(), charlist() | false}]
  def port_env(opts \\ [], base \\ []) when is_list(opts) and is_list(base) do
    allowlist = opts |> Keyword.get(:agent_env_allowlist, []) |> MapSet.new(&to_string/1)
    explicit = Keyword.get(opts, :agent_env, %{})

    scrubbed =
      @default_sensitive_keys
      |> Enum.reject(&MapSet.member?(allowlist, &1))
      |> Enum.map(&{String.to_charlist(&1), false})

    base ++ scrubbed ++ explicit_env(explicit)
  end

  defp explicit_env(env) when is_map(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(to_string(key)), env_value(value)} end)
  end

  defp explicit_env(env) when is_list(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(to_string(key)), env_value(value)} end)
  end

  defp explicit_env(_env), do: []

  defp env_value(false), do: false
  defp env_value(nil), do: false
  defp env_value(value), do: String.to_charlist(to_string(value))
end
