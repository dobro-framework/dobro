defmodule Dobro.Graphql.SchemaModulesTest do
  use ExUnit.Case, async: true

  defmodule Label do
    use Dobro.Schema

    schema do
      field(:name, :string)
    end
  end

  defmodule NotesContext do
  end

  defmodule SharedTypes do
    use Dobro.Graphql.Schema, types: [Dobro.Graphql.SchemaModulesTest.Label]
  end

  defmodule OwnedTypes do
    use Dobro.Graphql.Schema,
      types: [Dobro.Graphql.SchemaModulesTest.Label],
      emit: :owned
  end

  defmodule Schema do
    use Absinthe.Schema
    use Dobro.Graphql.Schema.Root, modules: [SharedTypes, OwnedTypes]

    query do
      field :health, :string do
        resolve(fn _, _ -> {:ok, "ok"} end)
      end
    end
  end

  test "shared notation emits a contract that no API context owns" do
    assert %Absinthe.Type.Object{identifier: :label} = Schema.__absinthe_type__(:label)

    assert %Absinthe.Type.InputObject{identifier: :label_input} =
             Schema.__absinthe_type__(:label_input)
  end

  test "an owned notation module leaves unowned contracts to the shared module" do
    assert Enum.any?(List.wrap(SharedTypes.__referenced_types__()), &match?({Label, _}, &1))
    refute Enum.any?(List.wrap(OwnedTypes.__referenced_types__()), &match?({Label, _}, &1))
  end

  test "owner_context picks the longest matching context" do
    map = %{
      Dobro.Graphql.SchemaModulesTest => :root,
      Dobro.Graphql.SchemaModulesTest.NotesContext => :notes
    }

    assert Dobro.Graphql.Schema.owner_context(Label, map) == Dobro.Graphql.SchemaModulesTest
    assert Dobro.Graphql.Schema.owner_context(NotesContext, map) == NotesContext
    assert Dobro.Graphql.Schema.owner_context(String, %{}) == nil
  end
end
