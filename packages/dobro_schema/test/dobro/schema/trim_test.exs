defmodule Dobro.Schema.TrimTest do
  use ExUnit.Case, async: true

  alias Dobro.Contract.Helpers

  defmodule WithTrim do
    use Dobro.Schema

    schema do
      field :name, :string, trim: true
      field :note, :string
      field :tags, list_of(:string), trim: true
    end

    def new(value), do: Helpers.new(__MODULE__, value)
  end

  defmodule RequiredTrim do
    use Dobro.Schema

    schema do
      field :name, :string, required: true, trim: true
    end

    def new(value), do: Helpers.new(__MODULE__, value)
  end

  test "trims leading and trailing whitespace when trim: true" do
    assert {:ok, result} = WithTrim.new(%{name: "  Ada  ", note: "  keep  "})
    assert result.name == "Ada"
    assert result.note == "  keep  "
  end

  test "blank-after-trim becomes absent (nil) for optional fields" do
    assert {:ok, result} = WithTrim.new(%{name: "   ", note: "x"})
    assert result.name == nil
    assert result.note == "x"
  end

  test "trims list_of(:string) items when trim: true" do
    assert {:ok, result} = WithTrim.new(%{tags: ["  a  ", " b", "   "]})
    # blank-after-trim items are skipped like empty strings
    assert result.tags == ["a", "b"]
  end

  test "required + trim rejects whitespace-only values" do
    assert {:error, errors} = RequiredTrim.new(%{name: "   "})
    assert Enum.any?(errors, &(&1.path == :name and &1.reason == :required))
  end
end
