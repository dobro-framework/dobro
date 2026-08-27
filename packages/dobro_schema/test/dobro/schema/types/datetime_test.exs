defmodule Dobro.Schema.Types.DateTimeTest do
  use ExUnit.Case, async: true

  alias Dobro.Schema.Types.DateTime

  test "passes through DateTime structs" do
    value = ~U[2024-01-01 12:00:00Z]
    assert DateTime.new(value) == value
  end

  test "converts NaiveDateTime to UTC DateTime" do
    assert DateTime.new(~N[2024-01-01 12:00:00]) == ~U[2024-01-01 12:00:00Z]
  end

  test "parses ISO8601 strings to DateTime" do
    assert DateTime.new("2024-01-01T12:00:00Z") == ~U[2024-01-01 12:00:00Z]
  end

  test "returns nil for nil and invalid values" do
    assert DateTime.new(nil) == nil
    assert DateTime.new("not-a-date") == nil
    assert DateTime.new(123) == nil
  end
end
