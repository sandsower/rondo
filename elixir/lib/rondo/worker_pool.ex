defmodule Rondo.WorkerPool do
  @moduledoc """
  Selects an SSH worker host for remote Claude runs.
  """

  alias Rondo.Config

  @type host :: %{
          id: String.t(),
          host: String.t(),
          user: String.t() | nil,
          port: pos_integer() | nil,
          max_concurrent_agents: pos_integer()
        }

  @spec enabled?() :: boolean()
  def enabled?, do: hosts() != []

  @spec hosts() :: [host()]
  def hosts do
    Config.worker_ssh_hosts()
    |> Enum.map(&normalize_host/1)
    |> Enum.reject(&is_nil/1)
  end

  @spec host_id(host() | map() | String.t() | nil) :: String.t() | nil
  def host_id(%{id: id}) when is_binary(id) and id != "", do: id
  def host_id(%{name: name}) when is_binary(name) and name != "", do: name
  def host_id(%{host: host}) when is_binary(host) and host != "", do: host
  def host_id(host) when is_binary(host) and host != "", do: host
  def host_id(_host), do: nil

  @spec select_host([map()], keyword()) :: {:ok, host()} | {:wait, atom()}
  def select_host(running_entries, opts \\ []) when is_list(running_entries) do
    case hosts() do
      [] -> {:wait, :no_workers_configured}
      hosts -> select_host_from_hosts(hosts, running_entries, opts)
    end
  end

  @spec host_loads([map()]) :: map()
  def host_loads(running_entries) when is_list(running_entries) do
    running_entries
    |> Enum.reduce(%{}, fn entry, acc ->
      case host_id(Map.get(entry, :worker_host) || Map.get(entry, "worker_host")) do
        nil -> acc
        id -> Map.update(acc, id, 1, &(&1 + 1))
      end
    end)
  end

  defp select_host_from_hosts(hosts, running_entries, opts) do
    loads = host_loads(running_entries)
    preferred = normalize_host_ref(Keyword.get(opts, :preferred_host) || Keyword.get(opts, :worker_host))

    if preferred && host_available?(preferred, hosts, loads) do
      {:ok, preferred}
    else
      hosts
      |> Enum.filter(&host_available?(&1, hosts, loads))
      |> case do
        [] -> {:wait, :all_hosts_at_capacity}
        available_hosts -> {:ok, least_loaded_host(available_hosts, hosts, loads)}
      end
    end
  end

  defp least_loaded_host(available_hosts, hosts, loads) do
    available_hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} -> {host_load(loads, host), host_order(hosts, host), index} end)
    |> elem(0)
  end

  defp host_available?(%{} = host, hosts, loads) do
    host in hosts and host_load(loads, host) < host_capacity(host)
  end

  defp host_load(loads, %{} = host) do
    Map.get(loads, host_id(host), 0)
  end

  defp host_capacity(%{max_concurrent_agents: max}) when is_integer(max) and max > 0, do: max

  defp host_order(hosts, %{} = host) do
    id = host_id(host)
    Enum.find_index(hosts, &(host_id(&1) == id))
  end

  defp normalize_host_ref(%{} = host), do: normalize_host(host)
  defp normalize_host_ref(id) when is_binary(id) and id != "", do: Enum.find(hosts(), &(host_id(&1) == id))
  defp normalize_host_ref(_other), do: nil

  defp normalize_host(%{} = host) do
    host_name = string_value(Map.get(host, :name) || Map.get(host, "name"))
    ssh_host = string_value(Map.get(host, :host) || Map.get(host, "host"))

    if is_binary(ssh_host) do
      %{
        id: host_name || ssh_host,
        host: ssh_host,
        user: optional_string(Map.get(host, :user) || Map.get(host, "user")),
        port: optional_port(Map.get(host, :port) || Map.get(host, "port")),
        max_concurrent_agents:
          optional_positive_integer(Map.get(host, :max_concurrent_agents) || Map.get(host, "max_concurrent_agents")) ||
            Config.worker_max_concurrent_agents_per_host()
      }
    end
  end

  defp string_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_value(_value), do: nil

  defp optional_string(value), do: string_value(value)

  defp optional_port(value) when is_integer(value) and value > 0, do: value
  defp optional_port(_value), do: nil

  defp optional_positive_integer(value) when is_integer(value) and value > 0, do: value
  defp optional_positive_integer(_value), do: nil
end
