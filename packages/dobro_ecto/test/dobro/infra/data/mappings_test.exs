defmodule Dobro.Infra.Data.MappingsTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Selection
  alias Dobro.Infra.Data.Mappings

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

    test "treats not-loaded associations as empty" do
      dto = %{role_links: %Ecto.Association.NotLoaded{}}
      assert [] == Mappings.get_association(dto, {:role_links, :role_id})
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
  end

  describe "association_selected?/3" do
    test "is selected when the mapped domain field is requested" do
      mappings = Mappings.normalize(associations: [role_ids: {:role_links, :role_id}])
      selection = %Selection{fields: MapSet.new([:id, :role_ids]), associations: %{}}

      assert Mappings.association_selected?(:role_links, selection, mappings)
      refute Mappings.association_selected?(:role_links, %{selection | fields: MapSet.new([:id])}, mappings)
    end
  end
end
