defmodule Dobro.ContractExtendsTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use Dobro.Contract

    defschema Fields do
      field :name, :string, required: true
      field :count, :integer, default: 0
    end

    defcontract Create, extends: Fields

    defcontract Update, extends: Fields do
      field :note, :string
      # Override parent required/default.
      field :count, :integer, required: true
    end
  end

  test "child inherits parent fields" do
    assert {:ok, %Sample.Create{name: "a"}} = Sample.Create.new(%{name: "a", count: 1})
    assert :name in Sample.Create.__fields__()
    assert :count in Sample.Create.__fields__()
  end

  test "child can add and override fields" do
    assert {:ok, %Sample.Update{name: "a", count: 2, note: "n"}} =
             Sample.Update.new(%{name: "a", count: 2, note: "n"})

    # Parent defaulted `count`; child marks it required.
    assert {:error, _} = Sample.Update.new(%{name: "a", note: "n"})
    assert :note in Sample.Update.__fields__()
  end
end
