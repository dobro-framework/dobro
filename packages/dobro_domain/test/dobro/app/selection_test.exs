defmodule Dobro.App.SelectionTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Selection

  defmodule MappingField do
    use Dobro.Schema

    schema do
      field :from, list_of(:string)
      field :to, :string
    end
  end

  defmodule Mapping do
    use Dobro.Schema

    schema do
      field :id, :id
      field :name, :string
      field :fields, list_of(MappingField)
    end
  end

  test "includes list_of fields when nested projection is present" do
    projected = %{id: :leaf, fields: %{from: :leaf, to: :leaf}}

    selection = Selection.from_projection(projected, Mapping)

    assert MapSet.member?(selection.fields, :id)
    assert MapSet.member?(selection.fields, :fields)
  end

  test "leaf and nested projections both count as selected scalars" do
    projected = %{name: :leaf}

    selection = Selection.from_projection(projected, Mapping)

    assert MapSet.equal?(selection.fields, MapSet.new([:name]))
  end
end
