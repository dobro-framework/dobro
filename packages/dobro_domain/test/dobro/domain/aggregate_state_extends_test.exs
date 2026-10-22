defmodule Dobro.Domain.AggregateStateExtendsTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use Dobro.Domain.Aggregate

    defschema Fields do
      field :name, :string, required: true
      field :enabled, :boolean, default: true
    end

    state extends: Fields do
      field :note, :string
    end
  end

  defmodule ExtendsOnly do
    use Dobro.Domain.Aggregate

    defschema Fields do
      field :name, :string, required: true
    end

    state extends: Fields
  end

  test "state inherits schema fields after version and before local fields" do
    fields = Sample.__fields__()

    assert :version in fields
    assert :id in fields
    assert :name in fields
    assert :enabled in fields
    assert :note in fields

    assert Enum.find_index(Enum.reverse(fields), &(&1 == :version)) <
             Enum.find_index(Enum.reverse(fields), &(&1 == :id))

    assert Enum.find_index(Enum.reverse(fields), &(&1 == :id)) <
             Enum.find_index(Enum.reverse(fields), &(&1 == :name))

    assert Enum.find_index(Enum.reverse(fields), &(&1 == :name)) <
             Enum.find_index(Enum.reverse(fields), &(&1 == :note))
  end

  test "state extends: Parent without a do block injects version and identity" do
    fields = ExtendsOnly.__fields__()

    assert :version in fields
    assert :id in fields
    assert :name in fields
    assert ExtendsOnly.__identity_field__() == :id
  end
end
