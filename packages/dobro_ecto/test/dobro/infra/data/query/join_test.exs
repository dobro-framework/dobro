defmodule Dobro.Infra.Data.Query.JoinTest do
  use ExUnit.Case, async: true

  alias Dobro.Ecto.Test.Schemas.{CategorySchema, MappingSchema, TenantSchema}
  alias Dobro.Infra.Data.Query.Join

  test "compiles belongs_to join from root schema association" do
    assert %{
             name: :tenant,
             schema: TenantSchema,
             source: :category,
             type: :left,
             on: {:category, :tenant_id, :tenant, :id}
           } = Join.compile!(CategorySchema, :tenant, :category, [type: :left], [])
  end

  test "compiles parallel joins from root schema" do
    tenant =
      Join.compile!(MappingSchema, :tenant, :mapping, [type: :inner], [])

    template =
      Join.compile!(MappingSchema, :template, :mapping, [type: :inner], [tenant])

    assert tenant.source == :mapping
    assert template.source == :mapping
    assert tenant.on == {:mapping, :tenant_id, :tenant, :id}
    assert template.on == {:mapping, :template_id, :template, :id}
  end

  test "compiles chained join through prior binding" do
    _tenant = Join.compile!(CategorySchema, :tenant, :category, [], [])

    assert_raise ArgumentError, ~r/through :tenant.*not defined above/, fn ->
      Join.compile!(TenantSchema, :office, :category, [through: :tenant], [])
    end

    chained = Join.compile!(CategorySchema, :tenant, :category, [], [])
    assert chained.name == :tenant
  end
end
