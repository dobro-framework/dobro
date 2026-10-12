defmodule Dobro.State.OneOfInputTest do
  use ExUnit.Case, async: true

  defmodule Leaf do
    use Dobro.Schema

    schema do
      field :name, :string, required: true
    end

    def new(value), do: Dobro.Contract.Helpers.new(__MODULE__, value)
  end

  defmodule Group do
    use Dobro.Schema

    schema do
      field :label, :string, required: true
    end

    def new(value), do: Dobro.Contract.Helpers.new(__MODULE__, value)
  end

  defmodule Node do
    use Dobro.Schema.OneOf,
      types: [Leaf, Group],
      discr: &__MODULE__.discr/1

    def discr(%{__struct__: Leaf}), do: Leaf
    def discr(%{__struct__: Group}), do: Group
    def discr(%{label: _}), do: Group
    def discr(%{"label" => _}), do: Group
    def discr(_), do: Leaf
  end

  defmodule Envelope do
    use Dobro.Schema

    schema do
      field :node, Node, required: true
    end

    def new(value), do: Dobro.Contract.Helpers.new(__MODULE__, value)
  end

  test "casts keyed exclusive envelope into the member struct" do
    assert {:ok, %Envelope{node: %Leaf{name: "x"}}} =
             Envelope.new(%{node: %{leaf: %{name: "x"}}})
  end

  test "casts untagged member-shaped maps" do
    assert {:ok, %Envelope{node: %Group{label: "g"}}} =
             Envelope.new(%{node: %{label: "g"}})
  end

  test "rejects multiple exclusive keys" do
    assert {:error, errors} =
             Envelope.new(%{node: %{leaf: %{name: "x"}, group: %{label: "g"}}})

    assert Enum.any?(List.wrap(errors), fn
             %{reason: :one_of_exclusive} -> true
             _ -> false
           end)
  end
end
