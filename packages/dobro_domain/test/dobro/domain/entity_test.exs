defmodule Dobro.Domain.EntityTest do
  use ExUnit.Case, async: true

  defmodule OrderLine do
    use Dobro.Domain.Entity

    schema do
      field :product_id, :id, required: true
      field :quantity, :integer, required: true
    end

    definvariant quantity_positive(%{quantity: q}) when is_integer(q) and q > 0, do: :ok
    definvariant quantity_positive(_), do: {:error, :quantity_must_be_positive}
  end

  defmodule LineWithCustomId do
    use Dobro.Domain.Entity, identity: :line_id

    schema do
      field :quantity, :integer, required: true
    end
  end

  test "injects default :id identity field" do
    assert OrderLine.__identity_field__() == :id
    assert :id in OrderLine.__fields__()
  end

  test "injects custom identity field" do
    assert LineWithCustomId.__identity_field__() == :line_id
    assert :line_id in LineWithCustomId.__fields__()
    refute :id in LineWithCustomId.__fields__()
  end

  test "new/1 validates and runs invariants" do
    assert {:ok, line} = OrderLine.new(%{id: 1, product_id: 10, quantity: 2})
    assert line.id == 1
    assert line.quantity == 2

    assert {:error, _} = OrderLine.new(%{id: 1, product_id: 10, quantity: 0})
  end

  test "load/1 hydrates without validation" do
    assert {:ok, line} = OrderLine.load(%{id: 1, product_id: 10, quantity: 0})
    assert line.quantity == 0
  end

  test "equal?/2 compares by identity only" do
    {:ok, a} = OrderLine.load(%{id: 1, product_id: 10, quantity: 1})
    {:ok, b} = OrderLine.load(%{id: 1, product_id: 99, quantity: 9})
    {:ok, c} = OrderLine.load(%{id: 2, product_id: 10, quantity: 1})

    assert OrderLine.equal?(a, b)
    refute OrderLine.equal?(a, c)
  end

  test "identity/1 returns the identity field value" do
    {:ok, line} = OrderLine.load(%{id: 7, product_id: 1, quantity: 1})
    assert OrderLine.identity(line) == 7

    {:ok, custom} = LineWithCustomId.load(%{line_id: 3, quantity: 1})
    assert LineWithCustomId.identity(custom) == 3
  end

  test "value/1 returns field map" do
    {:ok, line} = OrderLine.load(%{id: 1, product_id: 10, quantity: 2})
    assert OrderLine.value(line) == %{id: 1, product_id: 10, quantity: 2}
  end

  test "DomainValue.load/2 hydrates list_of(Entity)" do
    alias Dobro.Schema.{DomainValue, ListOf}

    assert {:ok, [line]} =
             DomainValue.load([%{id: 1, product_id: 10, quantity: 2}], ListOf.new(OrderLine))

    assert %OrderLine{id: 1, product_id: 10, quantity: 2} = line
  end
end
