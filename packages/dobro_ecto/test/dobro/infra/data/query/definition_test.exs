defmodule Dobro.Infra.Data.Query.DefinitionTest do
  use ExUnit.Case, async: true

  alias Dobro.Ecto.Test.CategoryReadRepo
  alias Dobro.Ecto.Test.CategoryReadRepo.{GetCategory, ListCategories}
  alias Dobro.Infra.Data.ReadRepo

  test "compiles query modules with specs" do
    assert %Dobro.Infra.Data.Query.Spec{type: :one, preloads: preloads, joins: joins, fields: one_fields} =
             GetCategory.__spec__()

    assert is_list(preloads)
    assert joins == []
    assert Map.has_key?(one_fields, :id)
    assert Map.has_key?(one_fields, :name)

    list_spec = ListCategories.__spec__()
    assert list_spec.type == :list
    assert list_spec.root_binding == :category
    assert list_spec.query == {CategoryReadRepo, :__query_ListCategories__, 2}
    assert MapSet.equal?(list_spec.filterable, MapSet.new([:name]))
    assert MapSet.equal?(list_spec.sortable, MapSet.new([:name]))
    assert Map.has_key?(list_spec.fields, :name)
  end

  defmodule DefaultQueryablePort do
    use Dobro.Spec.Port
    @callback list_items(map(), term()) :: {:ok, term()} | {:error, term()}
  end

  defmodule DefaultQueryableRepo do
    use Dobro.Infra.Data.ReadRepo,
      port: Dobro.Infra.Data.Query.DefinitionTest.DefaultQueryablePort,
      schema: Dobro.Ecto.Test.Schemas.CategorySchema,
      tenant_strategy: nil

    defquery ListItems, type: :list do
      field :id, filterable: true, sortable: true
      field :name
      field :identifier, filterable: false

      join :tenant, type: :left do
        field :tenant_name, :name, sortable: true
      end

      field :value, filterable: false, sortable: false
    end
  end

  test "declared fields default to filterable and sortable" do
    spec = DefaultQueryableRepo.ListItems.__spec__()
    assert MapSet.member?(spec.filterable, :id)
    assert MapSet.member?(spec.filterable, :name)
    assert MapSet.member?(spec.filterable, :tenant_name)
    refute MapSet.member?(spec.filterable, :identifier)
    refute MapSet.member?(spec.filterable, :value)
    assert MapSet.member?(spec.sortable, :id)
    assert MapSet.member?(spec.sortable, :name)
    assert MapSet.member?(spec.sortable, :tenant_name)
    assert MapSet.member?(spec.sortable, :identifier)
    refute MapSet.member?(spec.sortable, :value)
  end

  defmodule NoBlockExistsPort do
    use Dobro.Spec.Port
    @callback item_exists?(map(), term()) :: boolean()
  end

  defmodule NoBlockExistsRepo do
    use Dobro.Infra.Data.ReadRepo,
      port: Dobro.Infra.Data.Query.DefinitionTest.NoBlockExistsPort,
      schema: Dobro.Ecto.Test.Schemas.CategorySchema,
      tenant_strategy: nil

    defquery ItemExists, type: :exists
  end

  test "allows defquery without a do block" do
    assert %Dobro.Infra.Data.Query.Spec{type: :exists} = NoBlockExistsRepo.ItemExists.__spec__()
  end

  defmodule FacetPort do
    use Dobro.Spec.Port
    @callback get_category_facet_values(map(), term()) :: {:ok, [String.t()]} | {:error, term()}
  end

  defmodule FacetRepo do
    import Ecto.Query

    use Dobro.Infra.Data.ReadRepo,
      port: Dobro.Infra.Data.Query.DefinitionTest.FacetPort,
      schema: Dobro.Ecto.Test.Schemas.CategorySchema,
      tenant_strategy: nil

    defquery GetCategoryFacetValues,
             type: :facet,
             as: :get_category_facet_values,
             facets: [:name, :status] do
      filterable [:status, :tenant_id]

      query fn _args, _ctx ->
        from(c in schema(), as: :category)
      end
    end
  end

  test "compiles facet queries with facets allow-list and filterable columns" do
    spec = FacetRepo.GetCategoryFacetValues.__spec__()

    assert spec.type == :facet
    assert MapSet.equal?(spec.facets, MapSet.new([:name, :status]))
    assert MapSet.equal?(spec.filterable, MapSet.new([:status, :tenant_id]))
    assert Map.has_key?(spec.fields, :name)
    assert Map.has_key?(spec.fields, :status)
    assert Map.has_key?(spec.fields, :tenant_id)
    assert spec.query == {FacetRepo, :__query_GetCategoryFacetValues__, 2}
    assert function_exported?(FacetRepo, :get_category_facet_values, 1)
  end

  test "defaults repo function name from the query module" do
    Code.ensure_loaded!(CategoryReadRepo)
    Code.ensure_loaded!(NoBlockExistsRepo)

    assert function_exported?(CategoryReadRepo, :list_categories, 1)
    assert function_exported?(CategoryReadRepo, :get_category, 1)
    assert function_exported?(NoBlockExistsRepo, :item_exists?, 1)
  end

  defmodule AsOverridePort do
    use Dobro.Spec.Port
    @callback custom_list(map(), term()) :: {:ok, term()} | {:error, term()}
  end

  defmodule AsOverrideRepo do
    use Dobro.Infra.Data.ReadRepo,
      port: Dobro.Infra.Data.Query.DefinitionTest.AsOverridePort,
      schema: Dobro.Ecto.Test.Schemas.CategorySchema,
      tenant_strategy: nil

    defquery ListItems, type: :list, as: :custom_list do
      fields [:id, :name]
    end

    defquery HiddenList, type: :list, as: false do
      fields [:id]
    end
  end

  test "allows overriding or disabling the default repo function name" do
    assert function_exported?(AsOverrideRepo, :custom_list, 1)
    refute function_exported?(AsOverrideRepo, :list_items, 1)
    refute function_exported?(AsOverrideRepo, :hidden_list, 1)
  end

  test "reads query defaults from use ReadRepo options" do
    assert ReadRepo.query_defaults(query_defaults: [include_global: false]) ==
             [include_global: false]

    assert ReadRepo.query_defaults([]) == []
  end

  describe "repo query defaults" do
    defmodule DefaultsTestPort do
      use Dobro.Spec.Port

      @callback default_query(map(), term()) :: {:ok, term()} | {:error, term()}
      @callback override_query(map(), term()) :: {:ok, term()} | {:error, term()}
    end

    defmodule DefaultsTestRepo do
      use Dobro.Infra.Data.ReadRepo,
        port: DefaultsTestPort,
        schema: Dobro.Ecto.Test.Schemas.CategorySchema,
        query_defaults: [include_global: false]

      defquery DefaultQuery, type: :one do
        fields [:id, :name, :identifier, :tenant_id]
      end

      defquery OverrideQuery, type: :one, include_global: true do
        fields [:id, :name, :identifier, :tenant_id]
      end
    end

    test "applies repo defaults to defquery specs" do
      assert DefaultsTestRepo.__query_defaults__() == [include_global: false]
      assert DefaultsTestRepo.DefaultQuery.__spec__().include_global == false
    end

    test "allows per-query override of repo defaults" do
      assert DefaultsTestRepo.OverrideQuery.__spec__().include_global == true
    end
  end
end
