defmodule Dobro.Domain.AggregateStateExtendsTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use Dobro.Domain.Aggregate

    defschema Fields do
      field :name, :string, required: true
      field :enabled, :boolean, default: true
    end

    state extends: Fields do
      field :id, :id, immutable: true
    end
  end

  test "state inherits schema fields after version and before local fields" do
    fields = Sample.__fields__()

    assert :version in fields
    assert :name in fields
    assert :enabled in fields
    assert :id in fields

    assert Enum.find_index(Enum.reverse(fields), &(&1 == :version)) <
             Enum.find_index(Enum.reverse(fields), &(&1 == :name))

    assert Enum.find_index(Enum.reverse(fields), &(&1 == :name)) <
             Enum.find_index(Enum.reverse(fields), &(&1 == :id))
  end
end
