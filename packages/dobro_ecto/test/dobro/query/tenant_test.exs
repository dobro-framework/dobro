defmodule Dobro.Query.TenantTest do
  use ExUnit.Case, async: true

  alias Dobro.Ecto.Test.Schemas.TemplateSchema
  alias Dobro.Query.Tenant

  describe "maybe_apply_tenant/3" do
    test "with nil tenant_id and include_global: true does not filter" do
      query = TemplateSchema |> Tenant.maybe_apply_tenant(nil, include_global: true)

      refute inspect(query) =~ "is_nil"
      refute inspect(query) =~ "tenant_id"
    end

    test "with nil tenant_id and include_global: false filters to global records" do
      query = TemplateSchema |> Tenant.maybe_apply_tenant(nil, include_global: false)

      assert inspect(query) =~ "is_nil"
    end

    test "with a tenant_id and include_global: false filters to exact tenant match" do
      query = TemplateSchema |> Tenant.maybe_apply_tenant(42, include_global: false)

      assert inspect(query) =~ "== ^42"
      refute inspect(query) =~ "or"
    end

    test "with a tenant_id and include_global: true includes tenant override logic" do
      query = TemplateSchema |> Tenant.maybe_apply_tenant(42, include_global: true, key: [:identifier])

      assert inspect(query) =~ "or"
      assert inspect(query) =~ "is_nil"
    end
  end
end
