defmodule Dobro.Infra.Data.MappingsTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Selection
  alias Dobro.Infra.Data.Mappings

  defmodule LineEntity do
    defstruct [:id, :quantity]
    def value(%__MODULE__{} = line), do: Map.from_struct(line)
  end

  describe "normalize/1" do
    test "normalises keyword mappings" do
      assert %{
               fields: %{abbreviation: {:in, :json_attributes}},
               associations: %{role_ids: {:role_links, :role_id}}
             } =
               Mappings.normalize(
                 fields: [abbreviation: {:in, :json_attributes}],
                 associations: [role_ids: {:role_links, :role_id}]
               )
    end
  end

  describe "field mappings" do
    test "reads and writes values inside a container" do
      dto = %{json_attributes: %{abbreviation: "ABC"}}

      assert "ABC" == Mappings.get_field(dto, :abbreviation, {:in, :json_attributes})

      assert %{json_attributes: %{abbreviation: "XYZ", phone_number: "1"}} ==
               dto
               |> Mappings.put_field(:abbreviation, "XYZ", {:in, :json_attributes})
               |> Mappings.put_field(:phone_number, "1", {:in, :json_attributes})
    end

    test "reads and writes renamed columns" do
      assert "Ada" == Mappings.get_field(%{name: "Ada"}, :display_name, :name)
      assert %{name: "Bob"} == Mappings.put_field(%{}, :display_name, "Bob", :name)
    end
  end

  describe "association mappings" do
    test "reads and writes id lists through association rows" do
      dto = %{role_links: [%{role_id: 3}, %{role_id: 4}]}

      assert [3, 4] == Mappings.get_association(dto, {:role_links, :role_id})

      assert %{role_links: [%{role_id: 5}]} ==
               Mappings.put_association(%{}, [5], {:role_links, :role_id})
    end

    test "reads and writes full entity rows through bare-atom associations" do
      dto = %{order_lines: [%{id: 1, quantity: 2, __meta__: :ecto}]}

      assert [%{id: 1, quantity: 2}] == Mappings.get_association(dto, :order_lines)

      entities = [%{id: 1, quantity: 3}, %{id: 2, quantity: 1}]
      assert %{order_lines: ^entities} = Mappings.put_association(%{}, entities, :order_lines)
    end

    test "dumps entity structs via value/1 when present" do
      line = %Dobro.Infra.Data.MappingsTest.LineEntity{id: 9, quantity: 4}

      assert %{order_lines: [%{id: 9, quantity: 4}]} ==
               Mappings.put_association(%{}, [line], :order_lines)
    end

    test "treats not-loaded associations as empty" do
      dto = %{role_links: %Ecto.Association.NotLoaded{}}
      assert [] == Mappings.get_association(dto, {:role_links, :role_id})
      assert [] == Mappings.get_association(dto, :role_links)
    end

    test "preload_names includes bare-atom associations" do
      mappings =
        Mappings.normalize(
          associations: [
            role_ids: {:role_links, :role_id},
            lines: :order_lines
          ]
        )

      assert Enum.sort(Mappings.preload_names(mappings)) == [:order_lines, :role_links]
    end
  end

  describe "apply_to_result/2" do
    test "projects association id lists onto the result" do
      mappings =
        Mappings.normalize(associations: [role_ids: {:role_links, :role_id}])

      result = %{id: 1, role_links: [%{role_id: 3}]}

      assert %{id: 1, role_links: [%{role_id: 3}], role_ids: [3]} ==
               Mappings.apply_to_result(result, mappings)
    end

    test "skips bare-atom entity associations" do
      mappings = Mappings.normalize(associations: [lines: :order_lines])
      result = %{id: 1, order_lines: [%{id: 2}]}

      assert result == Mappings.apply_to_result(result, mappings)
    end
  end

  describe "association_selected?/3" do
    test "is selected when the mapped domain field is requested" do
      mappings = Mappings.normalize(associations: [role_ids: {:role_links, :role_id}])
      selection = %Selection{fields: MapSet.new([:id, :role_ids]), associations: %{}}

      assert Mappings.association_selected?(:role_links, selection, mappings)
      refute Mappings.association_selected?(:role_links, %{selection | fields: MapSet.new([:id])}, mappings)
    end

    test "is selected for bare-atom association domain fields" do
      mappings = Mappings.normalize(associations: [lines: :order_lines])
      selection = %Selection{fields: MapSet.new([:lines]), associations: %{}}

      assert Mappings.association_selected?(:order_lines, selection, mappings)
    end
  end
end
