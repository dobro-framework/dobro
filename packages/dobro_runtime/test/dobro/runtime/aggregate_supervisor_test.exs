defmodule Dobro.Runtime.AggregateSupervisorTest do
  use ExUnit.Case, async: false

  alias Dobro.App.Auth.TenantContext
  alias Dobro.Runtime.ActorLock.Memory
  alias Dobro.Runtime.AggregateActor
  alias Dobro.Runtime.AggregateSupervisor

  defmodule StubWriteRepo do
    @moduledoc false

    def get_by(_identity, _context) do
      {:error, :not_found}
    end
  end

  defmodule SampleAggregate do
    @moduledoc false
  end

  setup do
    previous_lock = Application.get_env(:dobro_runtime, :actor_lock)
    previous_registry = Application.get_env(:dobro_spec, :adapter_registry)
    previous_write = Application.get_env(:dobro_spec, Dobro.Infra.Data.WriteRepo.Port)

    Application.put_env(:dobro_runtime, :actor_lock, {Memory, []})
    Application.put_env(:dobro_spec, :adapter_registry, Dobro.Runtime.TestAdapterRegistry)
    Application.put_env(:dobro_spec, Dobro.Infra.Data.WriteRepo.Port, StubWriteRepo)

    start_supervised!({Registry, keys: :unique, name: Dobro.Runtime.Registry})
    start_supervised!(Memory)
    start_supervised!({AggregateSupervisor, []})

    on_exit(fn ->
      restore(:dobro_runtime, :actor_lock, previous_lock)
      restore(:dobro_spec, :adapter_registry, previous_registry)
      restore(:dobro_spec, Dobro.Infra.Data.WriteRepo.Port, previous_write)
    end)

    :ok
  end

  test "concurrent ensure_started returns the same owner pid" do
    tenant = TenantContext.new(id: 1, identifier: "acme")
    identity = %{id: 42}
    parent = self()

    tasks =
      for i <- 1..8 do
        Task.async(fn ->
          result = AggregateSupervisor.ensure_started(SampleAggregate, tenant, identity)
          send(parent, {:done, i, result})
          result
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.all?(results, &match?({:ok, pid} when is_pid(pid), &1))

    pids = Enum.map(results, fn {:ok, pid} -> pid end)
    [owner | _] = Enum.uniq(pids)
    assert length(Enum.uniq(pids)) == 1

    key = AggregateActor.actor_key(SampleAggregate, tenant, identity)
    assert {:ok, ^owner} = Memory.whereis(key)
  end

  test "second starter waits then resolves owner when first holds the lock" do
    tenant = TenantContext.new(id: 2, identifier: "beta")
    identity = %{id: 7}
    key = AggregateActor.actor_key(SampleAggregate, tenant, identity)

    assert {:ok, owner} = AggregateSupervisor.ensure_started(SampleAggregate, tenant, identity)
    assert {:ok, ^owner} = Memory.whereis(key)

    assert {:ok, ^owner} = AggregateSupervisor.ensure_started(SampleAggregate, tenant, identity)
  end

  test "releasing lock allows a new owner after terminate" do
    tenant = TenantContext.new(id: 3, identifier: "gamma")
    identity = %{id: 9}
    key = AggregateActor.actor_key(SampleAggregate, tenant, identity)

    assert {:ok, owner} = AggregateSupervisor.ensure_started(SampleAggregate, tenant, identity)
    ref = Process.monitor(owner)
    GenServer.stop(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}

    assert :unknown = Memory.whereis(key)
    assert {:ok, new_owner} = AggregateSupervisor.ensure_started(SampleAggregate, tenant, identity)
    assert new_owner != owner
    assert Process.alive?(new_owner)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
