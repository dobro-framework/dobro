defmodule Dobro.Runtime.AggregateSupervisor do
  @moduledoc """
  Supervisor for the AggregateActor
  """
  use DynamicSupervisor

  alias Dobro.Error
  alias Dobro.Runtime.AggregateActor
  alias Dobro.Tenant

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_aggregate_actor(aggregate_module, tenant, identity, opts \\ []) do
    with {:ok, tenant} <- Tenant.normalize(tenant) do
      DynamicSupervisor.start_child(
        __MODULE__,
        {AggregateActor,
         aggregate_module: aggregate_module,
         identity: identity,
         tenant: tenant,
         persistence_strategy: Keyword.get(opts, :persistence_strategy, :stateful),
         name: actor_name(aggregate_module, tenant, identity)}
      )
      |> case do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp actor_name(aggregate_module, tenant, identity) do
    AggregateActor.actor_name(aggregate_module, tenant, identity)
  end

  @doc """
  Ensures an aggregate actor is running for the given identity.

  Normalizes the tenant first (resolving `:id` from `:identifier` when needed)
  and keys the actor by immutable tenant id so identifier renames cannot split
  the concurrency gateway.
  """
  def ensure_started(aggregate_module, tenant, identity, opts \\ []) do
    with {:ok, tenant} <- Tenant.normalize(tenant) do
      actor_name = actor_name(aggregate_module, tenant, identity)

      case Registry.lookup(Dobro.Runtime.Registry, actor_name) do
        [{pid, _}] -> {:ok, pid}
        [] -> start_aggregate_actor(aggregate_module, tenant, identity, opts)
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(reason)}
    end
  end
end
