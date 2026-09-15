defmodule Dobro.Runtime.AggregateSupervisor do
  @moduledoc """
  DynamicSupervisor for aggregate actors with optional cluster-wide locking.
  """
  use DynamicSupervisor

  alias Dobro.Error
  alias Dobro.Runtime.ActorLock
  alias Dobro.Runtime.ActorRegistry
  alias Dobro.Runtime.AggregateActor
  alias Dobro.Tenant

  @max_ensure_attempts 8
  @retry_backoff_ms 25

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Ensures an aggregate actor is running for the given identity.

  Normalizes the tenant first and keys the actor by immutable tenant id.
  In cluster mode the actor acquires an `ActorLock` on start, or this call
  routes to the existing owner via `whereis/1`.
  """
  def ensure_started(aggregate_module, tenant, identity, opts \\ []) do
    with {:ok, tenant} <- Tenant.normalize(tenant) do
      key = AggregateActor.actor_key(aggregate_module, tenant, identity)
      do_ensure_started(aggregate_module, tenant, identity, key, opts, @max_ensure_attempts)
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(reason)}
    end
  end

  @doc "Looks up a locally registered aggregate actor pid."
  def local_lookup(key) do
    ActorRegistry.lookup(key)
  end

  defp do_ensure_started(_mod, _tenant, _identity, _key, _opts, 0) do
    {:error, Error.new(:aggregate_unavailable)}
  end

  defp do_ensure_started(aggregate_module, tenant, identity, key, opts, attempts) do
    case resolve_owner(key) do
      {:ok, pid} ->
        {:ok, pid}

      :miss ->
        case start_aggregate_actor(aggregate_module, tenant, identity, key, opts) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, {:shutdown, :lock_not_acquired}} ->
            retry(aggregate_module, tenant, identity, key, opts, attempts)

          {:error, :lock_not_acquired} ->
            retry(aggregate_module, tenant, identity, key, opts, attempts)

          {:error, reason} ->
            {:error, wrap_error(reason)}
        end
    end
  end

  defp resolve_owner(key) do
    self_node = Node.self()

    case ActorRegistry.lookup(key) do
      {:ok, pid} ->
        {:ok, pid}

      :miss ->
        case ActorLock.whereis(key) do
          {:ok, pid} when is_pid(pid) ->
            {:ok, pid}

          {:ok, node, pid} when is_pid(pid) and node != self_node ->
            {:ok, pid}

          {:ok, node, nil} when node != self_node ->
            case :erpc.call(node, __MODULE__, :local_lookup, [key]) do
              {:ok, pid} -> {:ok, pid}
              _ -> :miss
            end

          _ ->
            :miss
        end
    end
  end

  defp retry(aggregate_module, tenant, identity, key, opts, attempts) do
    Process.sleep(@retry_backoff_ms)
    do_ensure_started(aggregate_module, tenant, identity, key, opts, attempts - 1)
  end

  defp start_aggregate_actor(aggregate_module, tenant, identity, key, opts) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {AggregateActor,
       aggregate_module: aggregate_module,
       identity: identity,
       tenant: tenant,
       persistence_strategy: Keyword.get(opts, :persistence_strategy, :stateful),
       actor_key: key,
       name: ActorRegistry.via(key)}
    )
  end

  defp wrap_error(%Error{} = error), do: error
  defp wrap_error(reason), do: Error.new(reason)
end
