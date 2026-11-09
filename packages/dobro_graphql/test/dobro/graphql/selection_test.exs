defmodule Dobro.Graphql.SelectionTest do
  use ExUnit.Case, async: true

  alias Absinthe.Blueprint.Document.Field
  alias Absinthe.Blueprint.Document.Fragment
  alias Absinthe.Resolution
  alias Dobro.App.Selection
  alias Dobro.Graphql.Selection, as: GraphqlSelection
  alias Dobro.Graphql.TestFixtures.{CategoryList, CategoryListItem, PeopleInvolved}

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

  test "from_mutation_projected_fields digs into payload result selections" do
    projected = [
      %Field{name: "successful", selections: []},
      %Field{name: "messages", selections: [%Field{name: "message", selections: []}]},
      %Field{
        name: "result",
        selections: [
          %Field{name: "caseId", selections: []},
          %Field{name: "comments", selections: []},
          %Field{
            name: "nextOfKin",
            selections: [
              %Field{name: "personId", selections: []},
              %Field{name: "relationship", selections: []}
            ]
          },
          %Field{
            name: "additionalContacts",
            selections: [
              %Field{name: "personId", selections: []},
              %Field{name: "relationship", selections: []}
            ]
          }
        ]
      }
    ]

    selection =
      GraphqlSelection.from_mutation_projected_fields(projected, %Resolution{}, PeopleInvolved)

    assert MapSet.equal?(selection.fields, MapSet.new([:case_id, :comments]))
    assert Map.has_key?(selection.associations, :next_of_kin)
    assert Map.has_key?(selection.associations, :additional_contacts)

    assert MapSet.equal?(
             selection.associations.next_of_kin.fields,
             MapSet.new([:person_id, :relationship])
           )
  end

  test "from_mutation_projected_fields expands fragment spreads under result" do
    projected = [
      %Field{
        name: "result",
        selections: [%Fragment.Spread{name: "PeopleInvolvedFields"}]
      }
    ]

    resolution = %Resolution{
      fragments: %{
        "PeopleInvolvedFields" => %Fragment.Named{
          name: "PeopleInvolvedFields",
          type_condition: %Absinthe.Blueprint.TypeReference.Name{name: "PeopleInvolved"},
          selections: [
            %Field{name: "caseId", selections: []},
            %Field{
              name: "nextOfKin",
              selections: [%Field{name: "personId", selections: []}]
            }
          ]
        }
      }
    }

    selection =
      GraphqlSelection.from_mutation_projected_fields(projected, resolution, PeopleInvolved)

    assert MapSet.member?(selection.fields, :case_id)
    assert Map.has_key?(selection.associations, :next_of_kin)
  end

  test "from_mutation_projected_fields without result falls back to all scalars" do
    projected = [%Field{name: "successful", selections: []}]

    selection =
      GraphqlSelection.from_mutation_projected_fields(projected, %Resolution{}, PeopleInvolved)

    assert MapSet.member?(selection.fields, :case_id)
    assert MapSet.member?(selection.fields, :comments)
    assert selection.associations == %{}
  end

  defp list_item_selection(projected, item_module) do
    items = Map.get(projected, :items, %{})
    Selection.from_projection(items, item_module)
  end
end
