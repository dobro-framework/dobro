defmodule Dobro.Schema.NonNullTest do
  use ExUnit.Case, async: true

  alias Dobro.Error
  alias Dobro.Schema.TestFixtures.{StringList, TaggedItem, TaggedItemList}

  describe "non_null(:string)" do
    test "rejects empty string values" do
      assert {:error, errors} = TaggedItem.new(%{label: "", tags: ["a"]})

      assert Enum.any?(errors, &(&1.path == :label and &1.reason == :required))
    end
  end

  describe "list_of(non_null(:string))" do
    test "rejects empty string items with indexed paths" do
      assert {:error, errors} =
               TaggedItem.new(%{label: "item", tags: ["valid", ""]})

      assert Enum.any?(errors, &(&1.path == "tags[1]" and &1.reason == :required))
      refute Enum.any?(errors, &(&1.path == "tags[0]"))
    end

    test "rejects empty lists when required" do
      assert {:error, errors} = StringList.new(%{values: []})

      assert Enum.any?(errors, &(&1.path == :values and &1.reason == :required))
    end

    test "rejects empty required lists on nested contracts" do
      assert {:error, errors} =
               TaggedItem.new(%{label: "item", tags: []})

      assert Enum.any?(errors, &(&1.path == :tags and &1.reason == :required))
    end
  end

  describe "nested list contracts" do
    test "reports nested non_null errors with correct indices" do
      assert {:error, errors} =
               TaggedItemList.new(%{
                 items: [
                   %{label: "first", tags: ["a"]},
                   %{label: "second", tags: ["b", ""]}
                 ]
               })

      assert Enum.any?(
               errors,
               &match?(%Error{path: "items[1].tags[1]", reason: :required}, &1)
             )
    end

    test "reports empty required nested lists with correct indices" do
      assert {:error, errors} =
               TaggedItemList.new(%{
                 items: [
                   %{label: "first", tags: ["a"]},
                   %{label: "second", tags: []}
                 ]
               })

      assert Enum.any?(
               errors,
               &match?(%Error{path: "items[1].tags", reason: :required}, &1)
             )
    end
  end
end
