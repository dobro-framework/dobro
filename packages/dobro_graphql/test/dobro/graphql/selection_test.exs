defmodule Dobro.Graphql.SelectionTest do
  use ExUnit.Case, async: true

  alias Absinthe.Blueprint.Document.Field
  alias Absinthe.Blueprint.Document.Fragment
  alias Absinthe.Resolution
  alias Dobro.App.Selection
  alias Dobro.Graphql.Selection, as: GraphqlSelection
  alias Dobro.Graphql.TestFixtures.{CategoryList, CategoryListItem}

  test "extracts item field selection from list projection" do
    projected = %{
      items: %{id: :leaf, name: :leaf},
      meta: %{total_count: :leaf}
    }

    selection = list_item_selection(projected, CategoryListItem)

    assert MapSet.equal?(selection.fields, MapSet.new([:id, :name]))
  end

  test "captures list meta field selection" do
    projected = %{
      items: %{id: :leaf, name: :leaf},
      meta: %{total_count: :leaf, total_pages: :leaf}
    }

    selection =
      GraphqlSelection.from_projected_fields(projected, %Resolution{}, CategoryList)

    assert MapSet.equal?(selection.meta_fields, MapSet.new([:total_count, :total_pages]))
    assert Selection.total_count_selected?(selection)
  end

  test "total_count_selected? is false when meta is absent" do
    selection = %Selection{fields: MapSet.new([:id]), meta_fields: MapSet.new()}
    refute Selection.total_count_selected?(selection)
  end

  test "returns all item fields when items projection is empty" do
    selection = list_item_selection(%{items: %{}}, CategoryListItem)

    assert MapSet.member?(selection.fields, :id)
    assert MapSet.member?(selection.fields, :name)
    assert MapSet.member?(selection.fields, :identifier)
    assert MapSet.member?(selection.fields, :tenant_name)
  end

  test "expands nested fragment spreads into item field selection" do
    projected = [
      %Field{name: "meta", selections: [%Field{name: "totalCount", selections: []}]},
      %Field{
        name: "items",
        selections: [%Fragment.Spread{name: "CategoryListItemFields"}]
      }
    ]

    resolution = %Resolution{
      fragments: %{
        "CategoryListItemFields" => %Fragment.Named{
          name: "CategoryListItemFields",
          type_condition: %Absinthe.Blueprint.TypeReference.Name{name: "CategoryListItem"},
          selections: [
            %Field{name: "id", selections: []},
            %Field{name: "name", selections: []},
            %Field{name: "identifier", selections: []}
          ]
        }
      }
    }

    selection = GraphqlSelection.from_projected_fields(projected, resolution, CategoryList)

    assert MapSet.equal?(selection.fields, MapSet.new([:id, :name, :identifier]))
  end

  test "expands nested inline fragments into item field selection" do
    projected = [
      %Field{
        name: "items",
        selections: [
          %Fragment.Inline{
            type_condition: %Absinthe.Blueprint.TypeReference.Name{name: "CategoryListItem"},
            selections: [
              %Field{name: "id", selections: []},
              %Field{name: "tenantName", selections: []}
            ]
          }
        ]
      }
    ]

    selection = GraphqlSelection.from_projected_fields(projected, %Resolution{}, CategoryList)

    assert MapSet.equal?(selection.fields, MapSet.new([:id, :tenant_name]))
  end

  defp list_item_selection(projected, item_module) do
    items = Map.get(projected, :items, %{})
    Selection.from_projection(items, item_module)
  end
end
