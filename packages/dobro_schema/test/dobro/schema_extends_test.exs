defmodule Dobro.SchemaExtendsTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use Dobro.Schema

    defschema Fields do
      field :name, :string, required: true
      field :count, :integer, default: 0
    end

    defschema Create, extends: Fields

    defschema Update, extends: Fields do
      field :note, :string
      field :count, :integer, required: true
    end
  end

  test "child schema inherits parent fields" do
    assert :name in Sample.Create.__fields__()
    assert :count in Sample.Create.__fields__()
    assert {:ok, :string} = Sample.Create.type_for(:name)
  end

  test "child schema can add and override fields" do
    assert :note in Sample.Update.__fields__()

    {_type, opts} = Sample.Update.__schema__(:count)
    assert opts[:required] == true
  end
end
