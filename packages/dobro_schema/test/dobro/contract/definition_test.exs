defmodule Dobro.Contract.DefinitionTest do
  use ExUnit.Case, async: true

  defmodule Contracts do
    use Dobro.Contract

    defcontract Empty

    defcontract WithFields do
      field :name, :string, required: true
    end
  end

  test "defcontract/1 defines an empty contract" do
    assert {:ok, %Contracts.Empty{}} = Contracts.Empty.new(%{})
    assert Contracts.Empty in Contracts.__contracts__()
  end

  test "defcontract/2 still defines contracts with fields" do
    assert {:ok, %Contracts.WithFields{name: "Alpha"}} =
             Contracts.WithFields.new(%{name: "Alpha"})
  end
end
