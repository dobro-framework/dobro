defmodule Dobro.Schema.Types.AnyTest do
  use ExUnit.Case, async: true

  alias Dobro.Schema.Types.Any

  test "new/1 is a passthrough for any shape" do
    assert Any.new(nil) == nil
    assert Any.new("x") == "x"
    assert Any.new(1) == 1
    assert Any.new(true) == true
    assert Any.new([1, "a"]) == [1, "a"]
    assert Any.new(%{a: 1}) == %{a: 1}
  end

  test "presence validation" do
    assert Any.validate(nil, :presence) == {:error, :required}
    assert Any.validate("", :presence) == :ok
    assert Any.validate([], :presence) == :ok
    assert Any.validate(%{}, :presence) == :ok
  end
end
