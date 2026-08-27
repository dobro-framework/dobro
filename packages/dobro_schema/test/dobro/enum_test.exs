defmodule Dobro.EnumTest do
  use ExUnit.Case, async: true

  defmodule Example do
    use Dobro.Enum

    defenum Colour do
      description("A primary colour")

      value :red, description: "Red"
      value :green, description: "Green"
      value :blue, description: "Blue"
    end
  end

  alias Example.Colour

  test "exposes values and metadata" do
    assert Colour.__enum__?()
    assert Colour.singular?()
    assert Colour.values() == [:red, :green, :blue]
    assert Colour.description() == "A primary colour"
    assert Colour.value_opts()[:red][:description] == "Red"
  end

  test "casts atoms and strings" do
    assert Colour.cast(:red) == {:ok, :red}
    assert Colour.cast("red") == {:ok, :red}
    assert Colour.cast("RED") == {:ok, :red}
    assert Colour.cast(:RED) == {:ok, :red}
    assert Colour.new("Green") == {:ok, :green}
    assert Colour.load("BLUE") == {:ok, :blue}
  end

  test "rejects unknown values" do
    assert {:error, [%Dobro.Error{reason: :invalid_enum}]} = Colour.cast(:yellow)
    assert {:error, [%Dobro.Error{reason: :invalid_enum}]} = Colour.cast("yellow")
    assert {:error, [%Dobro.Error{reason: :invalid_enum}]} = Colour.cast(1)
  end

  test "Dobro.Enum.enum?/1 detects enum modules" do
    assert Dobro.Enum.enum?(Colour)
    refute Dobro.Enum.enum?(String)
    refute Dobro.Enum.enum?("nope")
  end
end
