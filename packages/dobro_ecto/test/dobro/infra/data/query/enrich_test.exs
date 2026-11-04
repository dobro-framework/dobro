defmodule Dobro.Infra.Data.Query.EnrichTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Selection
  alias Dobro.Infra.Data.Query.Enrich
  alias Dobro.Infra.Data.ReadRepo.Context

  defmodule Loader do
    def load(ids, context) do
      send(self(), {:loaded, ids, context})

      Map.new(ids, fn id ->
        {id, %{id: id, name: "Name #{id}"}}
      end)
    end
  end

  @enriches [
    %{path: [:next_of_kin], key: :person_id, into: :person, with: {Loader, :load}},
    %{path: [:additional_contacts], key: :person_id, into: :person, with: {Loader, :load}},
    %{path: [:coverage], key: :purchaser_person_id, into: :purchaser_person, with: {Loader, :load}},
    %{path: [:coverage], key: :covered_person_id, into: :covered_person, with: {Loader, :load}}
  ]

  test "batches keys across paths and stitches into maps and lists" do
    row = %{
      next_of_kin: %{"person_id" => 1, "relationship" => "Son"},
      additional_contacts: [
        %{person_id: 2, relationship: "Friend"},
        %{person_id: 1, relationship: "Also"}
      ],
      coverage: %{purchaser_person_id: 3, covered_person_id: 4}
    }

    context = Context.new([])
    enriched = Enrich.run(row, @enriches, context)

    assert_received {:loaded, ids, ^context}
    assert Enum.sort(ids) == [1, 2, 3, 4]

    assert enriched.next_of_kin == %{
             person_id: 1,
             relationship: "Son",
             person: %{id: 1, name: "Name 1"}
           }

    assert enriched.additional_contacts == [
             %{person_id: 2, relationship: "Friend", person: %{id: 2, name: "Name 2"}},
             %{person_id: 1, relationship: "Also", person: %{id: 1, name: "Name 1"}}
           ]

    assert enriched.coverage.purchaser_person == %{id: 3, name: "Name 3"}
    assert enriched.coverage.covered_person == %{id: 4, name: "Name 4"}
  end

  test "batches across list page items" do
    page = %{
      items: [
        %{next_of_kin: %{person_id: 10, relationship: "A"}, additional_contacts: [], coverage: %{}},
        %{next_of_kin: %{person_id: 11, relationship: "B"}, additional_contacts: [], coverage: %{}}
      ],
      meta: %{}
    }

    enriched = Enrich.run(page, Enum.take(@enriches, 1), Context.new([]))

    assert_received {:loaded, ids, _}
    assert Enum.sort(ids) == [10, 11]
    assert hd(enriched.items).next_of_kin.person.id == 10
    assert List.last(enriched.items).next_of_kin.person.id == 11
  end

  test "skips enrich when nested into is not selected" do
    selection = %Selection{
      associations: %{
        next_of_kin: %Selection{fields: MapSet.new([:person_id, :relationship])}
      }
    }

    row = %{next_of_kin: %{person_id: 1, relationship: "Son"}, additional_contacts: [], coverage: %{}}

    enriched =
      Enrich.run(row, Enum.take(@enriches, 1), Context.new(selection: selection))

    refute_received {:loaded, _, _}
    refute Map.has_key?(enriched.next_of_kin, :person)
  end

  test "runs enrich when into association is selected" do
    selection = %Selection{
      associations: %{
        next_of_kin: %Selection{
          fields: MapSet.new([:person_id]),
          associations: %{person: %Selection{fields: MapSet.new([:id, :name])}}
        }
      }
    }

    row = %{next_of_kin: %{person_id: 9, relationship: "X"}, additional_contacts: [], coverage: %{}}

    enriched =
      Enrich.run(row, Enum.take(@enriches, 1), Context.new(selection: selection))

    assert_received {:loaded, [9], _}
    assert enriched.next_of_kin.person.name == "Name 9"
  end

  test "runs enrich for list_of fields when parent field is selected" do
    selection = %Selection{fields: MapSet.new([:additional_contacts])}

    row = %{
      next_of_kin: nil,
      additional_contacts: [%{person_id: 5, relationship: "Pal"}],
      coverage: %{}
    }

    enriched =
      Enrich.run(row, Enum.slice(@enriches, 1, 1), Context.new(selection: selection))

    assert_received {:loaded, [5], _}
    assert hd(enriched.additional_contacts).person.id == 5
  end

  defmodule FakeQuery do
  end

  defmodule FakeRepo do
    def run(FakeQuery, %{ids: ids}, context) do
      send(self(), {:query_loaded, ids, context})

      {:ok,
       %{
         items:
           Enum.map(ids, fn id ->
             %{id: id, name: "Q#{id}", postcode: "P#{id}"}
           end)
       }}
    end
  end

  test "from-style query loader indexes list items by id" do
    enriches = [
      %{
        path: [:next_of_kin],
        key: :person_id,
        into: :person,
        with: {:query, FakeRepo, FakeQuery}
      }
    ]

    context = Context.new([])
    row = %{next_of_kin: %{person_id: 7, relationship: "Friend"}}

    enriched = Enrich.run(row, enriches, context)

    assert_received {:query_loaded, [7], ^context}
    assert enriched.next_of_kin.person == %{id: 7, name: "Q7", postcode: "P7"}
  end
end

