defmodule Rondo.RemoteShell do
  @moduledoc """
  Builds local shell commands that optionally hop over SSH to a remote worker host.
  """

  alias Rondo.WorkerPool

  @spec worker_host(keyword() | map() | term()) :: WorkerPool.host() | String.t() | nil
  def worker_host(opts) when is_list(opts), do: Keyword.get(opts, :worker_host)
  def worker_host(%{} = opts), do: Map.get(opts, :worker_host)
  def worker_host(_opts), do: nil

  @spec enabled?(keyword() | map() | term()) :: boolean()
  def enabled?(opts \\ []), do: not is_nil(worker_host(opts))

  @spec command_line(String.t(), keyword()) :: String.t()
  def command_line(command, opts \\ []), do: command_line_for_host(worker_host(opts), command)

  defp command_line_for_host(nil, command), do: command
  defp command_line_for_host(host, command) when is_binary(host), do: ssh_command_line(%{host: host}, command)
  defp command_line_for_host(host, command), do: ssh_command_line(host, command)

  @spec command_line_in_workspace(String.t(), Path.t(), keyword()) :: String.t()
  def command_line_in_workspace(command, workspace, opts \\ []) when is_binary(command) and is_binary(workspace), do: command_line("cd #{shell_escape(workspace)} && #{command}", opts)

  @spec run(String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def run(command, opts \\ []) when is_binary(command), do: System.cmd("sh", ["-lc", command_line(command, opts)], stderr_to_stdout: true)

  @spec run_in_workspace(String.t(), Path.t(), keyword()) :: {String.t(), non_neg_integer()}
  def run_in_workspace(command, workspace, opts \\ []) when is_binary(command) and is_binary(workspace), do: run("cd #{shell_escape(workspace)} && #{command}", opts)

  @spec spawn_invocation(String.t(), [String.t()], Path.t(), keyword()) :: {String.t(), [String.t()]}
  def spawn_invocation(command, args, workspace, opts \\ [])
      when is_binary(command) and is_list(args) and is_binary(workspace) do
    {shell_executable(), ["-lc", command_line_in_workspace(shell_command(command, args), workspace, opts)]}
  end

  @spec git_runner(keyword()) :: (list(String.t()), Path.t() -> {String.t(), non_neg_integer()})
  def git_runner(opts \\ []), do: fn args, workspace -> run_in_workspace("git #{shell_join(args)}", workspace, opts) end

  @spec shell_command(String.t(), [String.t()]) :: String.t()
  def shell_command(command, args) when is_binary(command) and is_list(args) do
    [command, shell_join(args)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp ssh_command_line(%{host: _host} = worker_host, command) do
    remote_target = ssh_target(worker_host)
    ssh_options = ssh_options(worker_host)
    remote_script = "sh -lc #{shell_escape(command)}"

    ["ssh", ssh_options, shell_escape(remote_target), remote_script]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp ssh_target(%{user: user, host: host}) when is_binary(user) and user != "", do: "#{user}@#{host}"
  defp ssh_target(%{host: host}) when is_binary(host), do: host

  defp ssh_options(worker_host) do
    [batch_mode_option(), strict_host_key_option(), port_option(worker_host)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp batch_mode_option, do: "-o BatchMode=yes"
  defp strict_host_key_option, do: "-o StrictHostKeyChecking=accept-new"

  defp port_option(%{port: port}) when is_integer(port) and port > 0, do: "-p #{port}"
  defp port_option(_worker_host), do: ""

  defp shell_join(args) when is_list(args) do
    Enum.map_join(args, " ", &shell_escape/1)
  end

  defp shell_executable do
    case System.find_executable("sh") do
      nil -> "/bin/sh"
      sh -> sh
    end
  end
end
