defmodule Dobro.Query.List.FilterTest do
  use ExUnit.Case, async: true

  alias Dobro.Query.List.Filter

  describe "parse_op/1" do
    test "accepts Flop string operator names" do
      assert {:ok, :==} = Filter.parse_op("==")
      assert {:ok, :!=} = Filter.parse_op("!=")
      assert {:ok, :=~} = Filter.parse_op("=~")
      assert {:ok, :empty} = Filter.parse_op("empty")
      assert {:ok, :not_empty} = Filter.parse_op("not_empty")
      assert {:ok, :<=} = Filter.parse_op("<=")
      assert {:ok, :<} = Filter.parse_op("<")
      assert {:ok, :>=} = Filter.parse_op(">=")
      assert {:ok, :>} = Filter.parse_op(">")
      assert {:ok, :in} = Filter.parse_op("in")
      assert {:ok, :not_in} = Filter.parse_op("not_in")
      assert {:ok, :contains} = Filter.parse_op("contains")
      assert {:ok, :not_contains} = Filter.parse_op("not_contains")
      assert {:ok, :like} = Filter.parse_op("like")
      assert {:ok, :not_like} = Filter.parse_op("not_like")
      assert {:ok, :like_and} = Filter.parse_op("like_and")
      assert {:ok, :like_or} = Filter.parse_op("like_or")
      assert {:ok, :ilike} = Filter.parse_op("ilike")
      assert {:ok, :not_ilike} = Filter.parse_op("not_ilike")
      assert {:ok, :ilike_and} = Filter.parse_op("ilike_and")
      assert {:ok, :ilike_or} = Filter.parse_op("ilike_or")
      assert {:ok, :starts_with} = Filter.parse_op("starts_with")
      assert {:ok, :ends_with} = Filter.parse_op("ends_with")
    end

    test "accepts legacy aliases" do
      assert {:ok, :==} = Filter.parse_op("=")
      assert {:ok, :==} = Filter.parse_op("eq")
    end

    test "rejects unknown operators" do
      assert {:error, :invalid_op} = Filter.parse_op("matches")
    end
  end

  describe "cast_value/3" do
    test "casts string integers to :id" do
      assert {:ok, 2} = Filter.cast_value(:id, :==, "2")
    end

    test "casts string integers to :integer" do
      assert {:ok, 42} = Filter.cast_value(:integer, :==, "42")
    end

    test "leaves strings typed as :string unchanged" do
      assert {:ok, "alpha"} = Filter.cast_value(:string, :==, "alpha")
    end

    test "casts boolean strings" do
      assert {:ok, true} = Filter.cast_value(:boolean, :==, "true")
      assert {:ok, false} = Filter.cast_value(:boolean, :==, "false")
    end

    test "casts each value for in/not_in" do
      assert {:ok, [1, 2, 3]} = Filter.cast_value(:id, :in, "1,2,3")
      assert {:ok, [1, 2]} = Filter.cast_value(:id, :not_in, ["1", "2"])
    end

    test "skips casting for empty/not_empty" do
      assert {:ok, "true"} = Filter.cast_value(:id, :empty, "true")
    end

    test "keeps pattern-operator values as strings for non-string columns" do
      assert {:ok, "12"} = Filter.cast_value(:id, :ilike, "12")
      assert {:ok, "not-an-id"} = Filter.cast_value(:id, :ilike, "not-an-id")
      assert {:ok, "alpha"} = Filter.cast_value(:integer, :starts_with, "alpha")
    end

    test "passes through when type is unknown" do
      assert {:ok, "2"} = Filter.cast_value(nil, :==, "2")
    end

    test "returns error for invalid casts" do
      assert {:error, :invalid_filter_value} = Filter.cast_value(:id, :==, "not-an-id")
      assert {:error, :invalid_filter_value} = Filter.cast_value(:integer, :in, "1,x,3")
    end
  end
end
