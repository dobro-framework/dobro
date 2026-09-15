defmodule Dobro.Runtime.ActorLock.Memory do
  @moduledoc """
  In-memory actor lock for tests and single-process multi-owner simulation.

  Not safe across BEAM nodes — use `ActorLock.Postgres` in production clusters.
  """

  @behaviour Dobro.Runtime.ActorLock

  use GenServer

  @lock_released {Dobro.Runtime.ActorLock.Postgres, :lock_released}

  def child_specs(opts \\ []) do
    [
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def try_acquire(key, owner) when is_pid(owner) do
    GenServer.call(__MODULE__, {:try_acquire, key, owner})
  end

  @impl true
  def release(key) do
    GenServer.call(__MODULE__, {:release, key})
  end

  @impl true
  def whereis(key) do
    GenServer.call(__MODULE__, {:whereis, key})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{locks: %{}}}

  @impl GenServer
  def handle_call({:try_acquire, key, owner}, _from, state) do
    case Map.get(state.locks, key) do
      nil ->
        monitor = Process.monitor(owner)
        locks = Map.put(state.locks, key, %{owner: owner, monitor: monitor, node: Node.self()})
        {:reply, :ok, %{state | locks: locks}}

      %{owner: ^owner} ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :locked}, state}
    end
  end

  def handle_call({:release, key}, _from, state) do
    {:reply, :ok, do_release(key, state)}
  end

  def handle_call({:whereis, key}, _from, state) do
    self_node = Node.self()

    reply =
      case Map.get(state.locks, key) do
        %{owner: owner, node: ^self_node} -> {:ok, owner}
        %{owner: owner, node: node} -> {:ok, node, owner}
        nil -> :unknown
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    key =
      Enum.find_value(state.locks, fn
        {k, %{monitor: ^monitor, owner: ^pid}} -> k
        _ -> nil
      end)

    state =
      if key do
        if Process.alive?(pid), do: send(pid, {@lock_released, key, reason})
        do_release(key, state)
      else
        state
      end

    {:noreply, state}
  end

  defp do_release(key, state) do
    case Map.pop(state.locks, key) do
      {nil, locks} ->
        %{state | locks: locks}

      {%{monitor: monitor}, locks} ->
        Process.demonitor(monitor, [:flush])
        %{state | locks: locks}
    end
  end
end
