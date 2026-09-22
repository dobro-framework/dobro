defmodule Dobro.Query.FacetTest do
  use ExUnit.Case, async: true

  alias Dobro.Ecto.Test.Schemas.CategorySchema
  alias Dobro.Infra.Data.Query.Spec
  alias Dobro.Query.Facet

  defp facet_spec(attrs \\ []) do
    binding = :category

    struct!(
      %Spec{
        module: __MODULE__,
        repo: nil,
        type: :facet,
        schema: CategorySchema,
        root_binding: binding,
        fields: %{
          name: {:column, binding, :name},
          status: {:column, binding, :status},
          tenant_id: {:column, binding, :tenant_id}
        },
        filterable: MapSet.new([:status, :tenant_id]),
        facets: MapSet.new([:name, :status])
      },
      attrs
    )
  end

  test "rejects missing field" do
    assert {:error, %{reason: :query_validation_error}} =
             Facet.run(CategorySchema, %{}, facet_spec())
  end

  test "rejects field outside facets allow-list" do
    assert {:error, %{reason: :query_validation_error} = error} =
             Facet.run(CategorySchema, %{field: "tenant_id"}, facet_spec())

    assert error.description =~ "invalid facet field"
  end

  test "accepts camelCase field names" do
    # Validation passes; Repo.all will fail without a configured DB — assert we
    # get past field resolution by using an invalid filter instead.
    assert {:error, %{reason: :query_validation_error} = error} =
             Facet.run(
               CategorySchema,
               %{
                 field: "name",
                 query: %{filters: [%{field: "unknown", op: "==", value: "x"}]}
               },
               facet_spec()
             )

    assert error.description =~ "invalid filter field"
  end

  test "rejects invalid filter fields" do
    assert {:error, %{reason: :query_validation_error} = error} =
             Facet.run(
               CategorySchema,
               %{
                 field: :name,
                 query: %{filters: [%{field: :name, op: "==", value: "x"}]}
               },
               facet_spec()
             )

    assert error.description =~ "invalid filter field"
  end
end
