defmodule Dobro.App.ScopePolicyTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.ExecutionContext
  alias Dobro.App.Scope
  alias Dobro.App.ScopePolicy
  alias Dobro.App.ScopePolicy.Error, as: ScopePolicyError
  alias Dobro.Ecto.Test.RepoPolicyFixtures.{GlobalRepo, SchemaTenantRepo, TenantIdRepo}

  test "allows global scope with shared read repo" do
    scope_context = Scope.setup!({:global, nil}, %ExecutionContext{})
    assert :ok = ScopePolicy.validate!(scope_context, GlobalRepo)
  end

  test "rejects global scope when repo only allows tenant scope" do
    scope_context = Scope.setup!({:global, nil}, %ExecutionContext{})

    assert_raise ScopePolicyError, fn ->
      ScopePolicy.validate!(scope_context, TenantIdRepo)
    end
  end

  test "rejects global scope with schema tenant strategy" do
    scope_context = Scope.setup!({:global, nil}, %ExecutionContext{})

    assert_raise ScopePolicyError, fn ->
      ScopePolicy.validate!(scope_context, SchemaTenantRepo)
    end
  end

  test "rejects tenant scope when repo only allows global scope" do
    tenant = %TenantContext{id: 1, identifier: "acme"}
    scope_context = Scope.setup!({:tenant, :context}, %ExecutionContext{tenant: tenant})

    assert_raise ScopePolicyError, fn ->
      ScopePolicy.validate!(scope_context, GlobalRepo)
    end
  end

  test "allows tenant scope with tenant-only read repo" do
    tenant = %TenantContext{id: 1, identifier: "acme"}
    scope_context = Scope.setup!({:tenant, :context}, %ExecutionContext{tenant: tenant})
    assert :ok = ScopePolicy.validate!(scope_context, TenantIdRepo)
  end

  test "normalises dynamic scope without tenant as global for repo policy" do
    scope_context = Scope.setup!({:dynamic, nil}, %ExecutionContext{})
    assert :ok = ScopePolicy.validate!(scope_context, GlobalRepo)
  end

  test "normalises dynamic scope with tenant as tenant for repo policy" do
    tenant = %TenantContext{id: 1, identifier: "acme"}
    scope_context = Scope.setup!({:dynamic, nil}, %ExecutionContext{tenant: tenant})
    assert :ok = ScopePolicy.validate!(scope_context, TenantIdRepo)
  end

  test "rejects dynamic scope without tenant against tenant-only read repo" do
    scope_context = Scope.setup!({:dynamic, nil}, %ExecutionContext{})

    assert_raise ScopePolicyError, fn ->
      ScopePolicy.validate!(scope_context, TenantIdRepo)
    end
  end
end
