defmodule Dobro.App.ScopePolicyTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.{GlobalContext, TenantContext}
  alias Dobro.App.ScopePolicy
  alias Dobro.App.ScopePolicy.Error, as: ScopePolicyError
  alias Dobro.Ecto.Test.RepoPolicyFixtures.{GlobalRepo, SchemaTenantRepo, TenantIdRepo}

  @tenant %TenantContext{id: 1, identifier: "acme"}

  test "allows a global request on a repo that serves global scope" do
    assert :ok = ScopePolicy.validate_context!(GlobalContext.new(), GlobalRepo)
  end

  test "rejects a global request on a repo that serves only tenants" do
    assert_raise ScopePolicyError, fn ->
      ScopePolicy.validate_context!(GlobalContext.new(), TenantIdRepo)
    end
  end

  test "rejects a global request on a schema-per-tenant repo" do
    assert_raise ScopePolicyError, fn ->
      ScopePolicy.validate_context!(GlobalContext.new(), SchemaTenantRepo)
    end
  end

  test "rejects a tenant request on a repo that serves only global scope" do
    assert_raise ScopePolicyError, fn ->
      ScopePolicy.validate_context!(@tenant, GlobalRepo)
    end
  end

  test "allows a tenant request on a repo that serves tenants" do
    assert :ok = ScopePolicy.validate_context!(@tenant, TenantIdRepo)
  end
end
