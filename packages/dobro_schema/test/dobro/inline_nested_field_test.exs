defmodule Dobro.InlineNestedFieldTest do
  use ExUnit.Case, async: true

  defmodule SchemaSample do
    use Dobro.Schema

    defschema Parent do
      field :label, :string

      field :meta, Meta do
        field :count, :integer, default: 0
      end
    end
  end

  defmodule ContractSample do
    use Dobro.Contract

    defcontract Parent do
      field :label, :string, required: true

      field :meta, Meta do
        field :count, :integer, required: true
      end
    end
  end

  test "inline field under defschema nests a schema module" do
    assert :count in SchemaSample.Parent.Meta.__fields__()
    assert :meta in SchemaSample.Parent.__fields__()
    refute function_exported?(SchemaSample.Parent.Meta, :new, 1)

    {type, _opts} = SchemaSample.Parent.__schema__(:meta)
    assert type == SchemaSample.Parent.Meta
  end

  test "inline field under defcontract nests a castable contract" do
    assert function_exported?(ContractSample.Parent.Meta, :new, 1)

    assert {:ok, %ContractSample.Parent{label: "a", meta: %ContractSample.Parent.Meta{count: 2}}} =
             ContractSample.Parent.new(%{label: "a", meta: %{count: 2}})

    assert {:error, _} = ContractSample.Parent.new(%{label: "a", meta: %{}})
  end
end
