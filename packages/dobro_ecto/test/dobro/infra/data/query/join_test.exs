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
             on: {:category, :tenant_id, :tenant, :id},
             prefix: nil
           } = Join.compile!(CategorySchema, :tenant, :category, [type: :left], [])
  end

  test "compiles association join with prefix: :tenant" do
    assert %{
             name: :tenant,
             prefix: :tenant
           } =
             Join.compile!(CategorySchema, :tenant, :category, [type: :left, prefix: :tenant], [])
  end

  test "compiles explicit schema/on join without association" do
    assert %{
             name: :covered_person,
             assoc: nil,
             schema: TenantSchema,
             source: :category,
             type: :left,
             on: {:category, :tenant_id, :covered_person, :id},
             prefix: :tenant,
             and_not_deleted: nil
           } =
             Join.compile!(
               CategorySchema,
               :covered_person,
               :category,
               [
                 schema: TenantSchema,
                 type: :left,
                 prefix: :tenant,
                 on: {:tenant_id, :id}
               ],
               []
             )
  end

  test "compiles explicit on with expr left side and and_not_deleted" do
    left = {:expr, {__MODULE__, :coverage_id}}

    assert %{
             name: :covered_person,
             assoc: nil,
             on: {:category, ^left, :covered_person, :id},
             and_not_deleted: :deleted,
             prefix: :tenant
           } =
             Join.compile!(
               CategorySchema,
               :covered_person,
               :category,
               [
                 schema: TenantSchema,
                 type: :left,
                 prefix: :tenant,
                 and_not_deleted: true,
                 on: {left, :id}
               ],
               []
             )
  end

  test "explicit join requires on:" do
    assert_raise ArgumentError, ~r/requires on:/, fn ->
      Join.compile!(
        CategorySchema,
        :covered_person,
        :category,
        [schema: TenantSchema, type: :left],
        []
      )
    end
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
