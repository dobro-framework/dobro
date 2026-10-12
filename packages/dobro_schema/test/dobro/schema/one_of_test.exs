defmodule Dobro.Schema.OneOfTest do
  use ExUnit.Case, async: true
  import Dobro.Schema.OneOf, only: [defoneof: 3]

  defmodule Leaf do
    defstruct [:name]

    def new(%{} = input), do: {:ok, struct(__MODULE__, Map.take(input, [:name]))}
    def load(%{} = input), do: new(input)
  end

  defmodule Group do
    defstruct [:label]

    def new(%{} = input), do: {:ok, struct(__MODULE__, Map.take(input, [:label]))}
    def load(%{} = input), do: new(input)
  end

  defoneof SampleNode, types: [Leaf, Group] do
    def discr(%Leaf{}), do: Leaf
    def discr(%Group{}), do: Group
    def discr(%{label: _}), do: Group
    def discr(%{"label" => _}), do: Group
    def discr(_), do: Leaf
  end

  test "defoneof builds a OneOf module with resolve_type/1" do
    assert Dobro.Schema.OneOf.one_of?(SampleNode)
    assert SampleNode.__one_of_types__() == [Leaf, Group]
    assert SampleNode.resolve_type(%{name: "a"}) == Leaf
    assert SampleNode.resolve_type(%{label: "g"}) == Group
    assert SampleNode.resolve_type(%Leaf{name: "a"}) == Leaf
  end

  test "member_key uses underscored leaf module name" do
    assert Dobro.Schema.OneOf.member_key(Group) == :group
    assert Dobro.Schema.OneOf.keyed_variants(SampleNode) == [leaf: Leaf, group: Group]
  end
end
