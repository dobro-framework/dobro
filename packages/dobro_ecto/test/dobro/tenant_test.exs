defmodule Dobro.TenantTest do
  use ExUnit.Case, async: false

  alias Dobro.App.Auth.TenantContext
  alias Dobro.Tenant

  defmodule FakeResolver do
    @behaviour Dobro.Tenant.Resolver

    @impl Dobro.Tenant.Resolver
    def normalize(%TenantContext{id: id, identifier: identifier} = tenant)
        when not is_nil(id) and is_binary(identifier) and identifier != "" do
      {:ok, tenant}
    end

    def normalize(%TenantContext{id: id}) when not is_nil(id) do
      {:ok, TenantContext.new(id: id, identifier: "sdadas")}
    end

    def normalize(%TenantContext{id: nil, identifier: "sdadas"}) do
      {:ok, TenantContext.new(id: 61, identifier: "sdadas")}
    end

    def normalize(_), do: {:error, :tenant_not_found}

    @impl true
    def schema_prefix_for(%TenantContext{identifier: identifier}) when is_binary(identifier),
      do: {:ok, identifier}

    def schema_prefix_for(%TenantContext{id: 61}), do: {:ok, "sdadas"}
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

  describe "normalize/1" do
    test "nil remains global" do
      assert Tenant.normalize(nil) == {:ok, nil}
    end

    test "id-only contexts are enriched by the resolver" do
      assert {:ok, %{id: 61, identifier: "sdadas"}} =
               Tenant.normalize(TenantContext.new(id: 61))
    end

    test "complete contexts are returned unchanged" do
      tenant = TenantContext.new(id: 61, identifier: "sdadas")
      assert Tenant.normalize(tenant) == {:ok, tenant}
    end

    test "identifier-only resolves to an id for partitioning" do
      assert {:ok, %{id: 61, identifier: "sdadas"}} =
               Tenant.normalize(TenantContext.new(identifier: "sdadas"))
    end
  end

  describe "partition_key/1" do
    test "keys by tenant id for id-only and identifier-only access paths" do
      assert Tenant.partition_key(TenantContext.new(id: 61)) == {:ok, "id:61"}

      assert Tenant.partition_key(TenantContext.new(identifier: "sdadas")) ==
               {:ok, "id:61"}
    end

    test "renaming identifier would not change the partition key" do
      assert Tenant.partition_key(TenantContext.new(id: 61, identifier: "old-name")) ==
               Tenant.partition_key(TenantContext.new(id: 61, identifier: "new-name"))
    end
  end
end
