defmodule Dobro.Graphql.SelectionListItemLoadTest do
  @moduledoc """
  The item contract must be loaded before a paginated selection is flattened.

  `function_exported?/3` is false for a module that has not been loaded yet, which
  is the first timeline read after boot or a code reload.
  """

  use ExUnit.Case, async: false

  alias Absinthe.Blueprint.Document.Field
  alias Absinthe.Resolution
  alias Dobro.Graphql.Selection, as: GraphqlSelection
  alias Dobro.Graphql.TestFixtures.{UnloadableList, UnloadableListItem}

  test "item fields are selected when the item contract is not loaded yet" do
    :code.purge(UnloadableListItem)
    :code.delete(UnloadableListItem)
    :code.purge(UnloadableListItem)
    refute function_exported?(UnloadableListItem, :__schema__, 0)

    projected = [
      %Field{name: "caseId", selections: []},
      %Field{
        name: "items",
        selections: [
          %Field{name: "id", selections: []},
          %Field{name: "name", selections: []},
          %Field{name: "kind", selections: []}
        ]
      }
    ]

    selection = GraphqlSelection.from_projected_fields(projected, %Resolution{}, UnloadableList)

    assert MapSet.equal?(selection.fields, MapSet.new([:id, :name, :kind]))
    refute Map.has_key?(selection.associations, :items)
  end
end
