defmodule Dobro.App.ScopeTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.ExecutionContext
  alias Dobro.App.Scope
  alias Dobro.App.Scope.Error, as: ScopeError

  defmodule TenantPayloadQuery do
    @moduledoc false
    defstruct [:tenant_id, :tenant_identifier]

    def __scope__, do: {:tenant, :payload}
  end

  describe "setup/2" do
    test "global scope succeeds without tenant context" do
      assert {:ok, %{mode: :global, tenant: nil}} =
               Scope.setup({:global, nil}, %ExecutionContext{})
    end

    test "global scope rejects tenant context" do
      assert {:error, "Cannot be run in a tenant context"} =
               Scope.setup(
                 {:global, nil},
                 %ExecutionContext{tenant: %TenantContext{id: 1, identifier: "acme"}}
               )
    end

    test "tenant scope from payload accepts string tenant ids" do
      assert {:ok, %{mode: :tenant, tenant: %TenantContext{id: 42}}} =
               Scope.setup({:tenant, "42"}, %ExecutionContext{})
    end

    test "tenant scope from context requires tenant" do
      assert {:error, "Tenant context is required"} =
               Scope.setup({:tenant, :context}, %ExecutionContext{})
    end

    test "tenant scope from context resolves tenant" do
      tenant = %TenantContext{id: 1, identifier: "acme"}

      assert {:ok, %{mode: :tenant, tenant: ^tenant}} =
               Scope.setup({:tenant, :context}, %ExecutionContext{tenant: tenant})
    end

    test "tenant scope from payload resolves tenant id" do
      assert {:ok, %{mode: :tenant, tenant: %TenantContext{id: 42}}} =
               Scope.setup({:tenant, 42}, %ExecutionContext{})
    end

    test "tenant scope from payload reuses execution tenant when ids match" do
      tenant = %TenantContext{id: 42, identifier: "acme"}

      assert {:ok, %{mode: :tenant, tenant: ^tenant}} =
               Scope.setup({:tenant, 42}, %ExecutionContext{tenant: tenant})
    end

    test "tenant scope from payload does not reuse execution tenant when ids differ" do
      auth_tenant = %TenantContext{id: 1, identifier: "acme"}

      assert {:ok, %{mode: :tenant, tenant: %TenantContext{id: 42, identifier: nil}}} =
               Scope.setup({:tenant, 42}, %ExecutionContext{tenant: auth_tenant})
    end

    test "tenant scope from payload accepts tenant_identifier" do
      assert {:ok, %{mode: :tenant, tenant: %TenantContext{identifier: "acme", id: nil}}} =
               Scope.setup({:tenant, {:identifier, "acme"}}, %ExecutionContext{})
    end

    test "setup_for_query! accepts tenant_identifier on payload-scoped queries" do
      query = %TenantPayloadQuery{tenant_identifier: "acme"}

      assert %Scope.ScopeContext{tenant: %TenantContext{identifier: "acme"}} =
               Scope.setup_for_query!(query, %ExecutionContext{})
    end

    test "dynamic scope without tenant context" do
      assert {:ok, %{mode: :dynamic, tenant: nil}} =
               Scope.setup({:dynamic, nil}, %ExecutionContext{})
    end

    test "dynamic scope with tenant context" do
      tenant = %TenantContext{id: 1, identifier: "acme"}

      assert {:ok, %{mode: :dynamic, tenant: ^tenant}} =
               Scope.setup({:dynamic, nil}, %ExecutionContext{tenant: tenant})
    end
  end

  describe "setup!/2" do
    test "raises on invalid scope" do
      assert_raise ScopeError, "Invalid scope: {:nope, nil}", fn ->
        apply(Scope, :setup!, [{:nope, nil}, %ExecutionContext{}])
      end
    end
  end
end
