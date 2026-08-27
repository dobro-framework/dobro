defmodule Dobro.Schema.DefaultsTest do
  use ExUnit.Case, async: true

  defmodule WithUseDefaults do
    use Dobro.Schema, defaults: [required: true]

    schema do
      field :id, :id
      field :label, :string, required: false
    end
  end

  defmodule WithSchemaDefaults do
    use Dobro.Schema

    schema defaults: [required: true] do
      field :id, :id
    end
  end

  test "use defaults: [required: true] apply to fields without an explicit required opt" do
    assert {:id, {:id, opts}} = List.keyfind(WithUseDefaults.__schema__(), :id, 0)
    assert Keyword.get(opts, :required) == true
  end

  test "explicit field opts override use defaults" do
    assert {:label, {:string, opts}} = List.keyfind(WithUseDefaults.__schema__(), :label, 0)
    assert Keyword.get(opts, :required) == false
  end

  test "schema defaults: [required: true] apply when passed to schema/2" do
    assert {:id, {:id, opts}} = List.keyfind(WithSchemaDefaults.__schema__(), :id, 0)
    assert Keyword.get(opts, :required) == true
  end
end
