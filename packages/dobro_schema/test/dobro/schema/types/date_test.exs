defmodule Dobro.Schema.Types.DateTest do
  use ExUnit.Case, async: true

  alias Dobro.Schema.Types.Date

  test "passes through Date structs" do
    value = ~D[2024-01-01]
    assert Date.new(value) == value
  end

  test "converts DateTime and NaiveDateTime to Date" do
    assert Date.new(~U[2024-01-01 12:00:00Z]) == ~D[2024-01-01]
    assert Date.new(~N[2024-01-01 12:00:00]) == ~D[2024-01-01]
  end

  test "parses ISO8601 date strings" do
    assert Date.new("2024-01-01") == ~D[2024-01-01]
  end

  test "parses ISO8601 datetime strings to their date" do
    assert Date.new("2024-01-01T12:00:00Z") == ~D[2024-01-01]
  end

  test "rebuilds dates from year/month/day maps" do
    assert Date.new(%{year: 2024, month: 1, day: 1, calendar: Calendar.ISO}) ==
             ~D[2024-01-01]

    assert Date.new(%{year: 2024, month: 1, day: 1}) == ~D[2024-01-01]
  end

  test "returns nil for nil and invalid values" do
    assert Date.new(nil) == nil
    assert Date.new("not-a-date") == nil
    assert Date.new(123) == nil
    assert Date.new(%{year: 2024, month: 13, day: 1}) == nil
  end
end
