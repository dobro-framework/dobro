defmodule Dobro.DefschemaTest do
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

  test "defschema defines a schema module without contract helpers" do
    assert :name in Sample.Fields.__fields__()
    assert function_exported?(Sample.Fields, :__schema__, 0)
    refute function_exported?(Sample.Fields, :new, 1)
    refute function_exported?(Sample.Fields, :cast, 1)
  end

  test "defschema extends inherits and overrides fields" do
    assert :name in Sample.Create.__fields__()
    assert :count in Sample.Create.__fields__()
    assert :note in Sample.Update.__fields__()

    {_type, opts} = Sample.Update.__schema__(:count)
    assert opts[:required] == true
  end
end
