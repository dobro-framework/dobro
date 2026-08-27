defmodule Dobro.App.EventStoreTest do
  use ExUnit.Case, async: false

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.EventStore

  defmodule SampleAggregate do
    def __stream_name__, do: "sample"
  end

  defmodule FakeResolver do
    @behaviour Dobro.Tenant.Resolver

    @impl true
    def normalize(%TenantContext{id: id} = tenant) when not is_nil(id) do
      {:ok, tenant}
    end

    def normalize(%TenantContext{id: nil, identifier: "sdadas"}) do
      {:ok, TenantContext.new(id: 61, identifier: "sdadas")}
    end

    def normalize(_), do: {:error, :tenant_not_found}

    @impl true
    def schema_prefix_for(%TenantContext{identifier: identifier}) when is_binary(identifier),
      do: {:ok, identifier}

    def schema_prefix_for(%TenantContext{id: id}) when not is_nil(id),
      do: {:ok, "tenant-#{id}"}

    def schema_prefix_for(_), do: {:error, :tenant_not_found}

    @impl true
    def schema_prefix_for!(tenant) do
      {:ok, prefix} = schema_prefix_for(tenant)
      prefix
    end
  end

  setup do
    previous = Application.get_env(:dobro_ecto, :tenant_resolver)
    Application.put_env(:dobro_ecto, :tenant_resolver, FakeResolver)

    on_exit(fn ->
      if previous do
        Application.put_env(:dobro_ecto, :tenant_resolver, previous)
      else
        Application.delete_env(:dobro_ecto, :tenant_resolver)
      end
    end)

    :ok
  end

  describe "stream_id/3" do
    test "partitions by normalized tenant id" do
      stream =
        EventStore.stream_id(SampleAggregate, TenantContext.new(id: 61), %{id: 2})

      assert stream == "sample/id:61/id:2"
    end

    test "different tenant ids produce different streams for the same identity" do
      stream_60 =
        EventStore.stream_id(SampleAggregate, TenantContext.new(id: 60), %{id: 2})

      stream_61 =
        EventStore.stream_id(SampleAggregate, TenantContext.new(id: 61), %{id: 2})

      assert stream_60 != stream_61
    end

    test "id-only and identifier-only tenants share a stream for the same aggregate" do
      assert EventStore.stream_id(SampleAggregate, TenantContext.new(id: 61), %{id: 2}) ==
               EventStore.stream_id(
                 SampleAggregate,
                 TenantContext.new(identifier: "sdadas"),
                 %{id: 2}
               )
    end

    test "nil tenant uses the global partition" do
      assert EventStore.stream_id(SampleAggregate, nil, %{id: 1}) == "sample/global/id:1"
    end
  end
end
