defmodule Dobro.Infra.Data.Query.SpecTest do
  use ExUnit.Case, async: true

  alias Dobro.Ecto.Test.Schemas.{MappingSchema, TenantSchema}
  alias Dobro.Infra.Data.Query.Spec

  @query_spec %Spec{
    module: __MODULE__,
    type: :list,
    schema: MappingSchema,
    root_binding: :mapping,
    fields: %{
      tenant_name: {:join, :tenant, :name},
      region_name: {:join, :region, :name}
    },
    joins: [
      %{
        name: :tenant,
        source: :mapping,
        on: {:mapping, :tenant_id, :tenant, :id}
      },
      %{
        name: :region,
        source: :tenant,
        on: {:tenant, :region_id, :region, :id}
      }
    ]
  }

  test "infer_root_binding/1 derives binding from schema module name" do
    assert Spec.infer_root_binding(TenantSchema) == :tenant
  end

  test "joins_for_fields/2 includes transitive through dependencies in order" do
    joins = Spec.joins_for_fields(@query_spec, [:region_name])
    assert Enum.map(joins, & &1.name) == [:tenant, :region]
  end

  test "joins_for_fields/2 preserves definition order for parallel joins" do
    parallel_spec = %{
      @query_spec
      | joins: [
          List.first(@query_spec.joins),
          %{name: :template, source: :mapping, on: {:mapping, :template_id, :template, :id}}
        ],
        fields: %{
          template_name: {:join, :template, :name},
          tenant_name: {:join, :tenant, :name}
        }
    }

    joins = Spec.joins_for_fields(parallel_spec, [:template_name, :tenant_name])
    assert Enum.map(joins, & &1.name) == [:tenant, :template]
  end
end
