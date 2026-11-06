defmodule Dobro.Runtime.OutboxListener do
  @moduledoc """
  Listens for outbox notifications and wakes the poller for that stream or pattern.

  One connection stays in `LISTEN`. Inserts notify from the transaction that wrote
  the row, so a poller queries only after the row is visible. A dedicated
  connection is required: a pooled checkout cannot sit in `LISTEN`.
  """

  use GenServer

  require Logger

  alias Dobro.Infra.Data.OutboxNotify
  alias Dobro.Infra.Repo
  alias Dobro.Integration.Pattern

  @registry Dobro.Runtime.Registry
  @reconnect_ms 5_000

  @connection_keys ~w(
    hostname port database username password socket_dir
    ssl ssl_opts parameters connect_timeout handshake_timeout socket_options
  )a

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    send(self(), :connect)
    {:ok, %{conn: nil}}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    {:noreply, connect(state)}
  end

  def handle_info({:notification, _pid, _ref, channel, payload}, state) do
    cond do
      channel == OutboxNotify.domain_channel() -> wake_domain(payload)
      channel == OutboxNotify.integration_channel() -> wake_integration(payload)
      true -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{conn: pid} = state) do
    Logger.warning("outbox listener disconnected: #{inspect(reason)}")
    Process.send_after(self(), :connect, @reconnect_ms)
    {:noreply, %{state | conn: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp connect(%{conn: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    connect(%{state | conn: nil})
  end

  defp connect(state) do
    opts = Keyword.merge(connection_opts(), sync_connect: false, auto_reconnect: true)

    case Postgrex.Notifications.start_link(opts) do
      {:ok, pid} ->
        Postgrex.Notifications.listen(pid, OutboxNotify.domain_channel())
        Postgrex.Notifications.listen(pid, OutboxNotify.integration_channel())
        %{state | conn: pid}

      {:error, reason} ->
        Logger.warning("outbox listener failed to connect: #{inspect(reason)}")
        Process.send_after(self(), :connect, @reconnect_ms)
        state
    end
  end

  defp connection_opts do
    Repo.repo().config()
    |> Keyword.take(@connection_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp wake_domain(stream) when is_binary(stream) do
    select([{{{:domain_poller, :_, stream}, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(&send(&1, :notify))
  end

  defp wake_domain(_stream), do: :ok

  defp wake_integration(routing_key) when is_binary(routing_key) do
    select([{{{:integration_poller, :_, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {pattern, pid} ->
      if Pattern.match?(pattern, routing_key), do: send(pid, :notify)
    end)
  end

  defp wake_integration(_routing_key), do: :ok

  defp select(spec) do
    if Process.whereis(@registry) do
      Registry.select(@registry, spec)
    else
      []
    end
  end
end
