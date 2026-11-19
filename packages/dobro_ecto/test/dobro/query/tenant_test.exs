defmodule Dobro.Query.TenantTest do
  use ExUnit.Case, async: true

  alias Dobro.Ecto.Test.Schemas.TemplateSchema
  alias Dobro.Query.Tenant

  describe "maybe_apply_tenant/3" do
    test "nil tenant raises" do
      assert_raise Tenant.MissingTenantError, fn ->
        Tenant.maybe_apply_tenant(TemplateSchema, nil, include_global: true)
      end
    end

    test "GlobalContext applies no filter" do
      query =
        Tenant.maybe_apply_tenant(TemplateSchema, Dobro.App.Auth.GlobalContext.new(),
          include_global: true
        )

      refute inspect(query) =~ "is_nil"
      refute inspect(query) =~ "tenant_id"
    end

    test "working globally, owner [:global] keeps global rows" do
      query = global(owner: [:global])
      assert inspect(query) =~ "is_nil(t0.tenant_id)"
      refute inspect(query) =~ "not"
    end

    test "working globally, owner [:tenant] keeps every tenant's rows" do
      assert inspect(global(owner: [:tenant])) =~ "not is_nil(t0.tenant_id)"
    end

    test "working globally, owner [:tenant, :global] keeps every row" do
      refute inspect(global(owner: ["GLOBAL", "TENANT"])) =~ "tenant_id"
    end

    test "inside a tenant, owner [:global] keeps global rows only" do
      query = Tenant.maybe_apply_tenant(TemplateSchema, 42, owner: [:global])
      assert inspect(query) =~ "is_nil(t0.tenant_id)"
      refute inspect(query) =~ "^42"
    end

    test "inside a tenant, owner [:tenant] keeps that tenant's rows only" do
      query = Tenant.maybe_apply_tenant(TemplateSchema, 42, owner: [:tenant])
      assert inspect(query) =~ "== ^42"
      refute inspect(query) =~ "is_nil"
    end

    test "with a tenant_id and include_global: false filters to exact tenant match" do
      query = TemplateSchema |> Tenant.maybe_apply_tenant(42, include_global: false)

      assert inspect(query) =~ "== ^42"
      refute inspect(query) =~ "or"
    end

    test "with a tenant_id and include_global: true includes tenant override logic" do
      query =
        TemplateSchema |> Tenant.maybe_apply_tenant(42, include_global: true, key: [:identifier])

      assert inspect(query) =~ "or"
      assert inspect(query) =~ "is_nil"
    end
  end

  test "normalize_owner/1 keeps known owners in a fixed order" do
    assert Tenant.normalize_owner(nil) == nil
    assert Tenant.normalize_owner([]) == nil
    assert Tenant.normalize_owner(["GLOBAL", "tenant", "other"]) == [:tenant, :global]
  end

  defp global(opts),
    do: Tenant.maybe_apply_tenant(TemplateSchema, Dobro.App.Auth.GlobalContext.new(), opts)
end
