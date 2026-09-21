defmodule Dobro.App.QueryResultTest do
  use ExUnit.Case, async: true

  alias Dobro.App.ResultCaster
  alias Dobro.Pipeline

  defmodule ExampleQueries do
    use Dobro.App.QueryDefinition

    defcontract Item do
      field :id, :id
      field :name, :string
    end

    query GetItem do
      scope :global

      payload do
        field :id, :id, required: true
      end

      result Item
    end

    query Flag do
      scope :global
      payload do: nil
      result :boolean
    end

    query Untyped do
      scope :global
      payload do: nil
    end

    query_handler Handler do
      handle GetItem, query do
        pipeline(query)
        |> put_result(%{id: query.id, name: "Widget"})
        |> finalize(:result)
      end
    end
  end

  test "query.__result__/0 returns the declared contract" do
    assert ExampleQueries.GetItem.__result__() == ExampleQueries.Item
    assert ExampleQueries.Flag.__result__() == :boolean
    assert ExampleQueries.Untyped.__result__() == nil
  end

  test "query handler casts the payload to the query result type" do
    {:ok, query} = ExampleQueries.GetItem.new(%{id: 7})
    assert {:ok, %ExampleQueries.Item{id: 7, name: "Widget"}} = ExampleQueries.Handler.execute(query)
  end

  test "ResultCaster is a no-op when the value is already the result struct" do
    item = %ExampleQueries.Item{id: 1, name: "A"}
    assert {:ok, ^item} = ResultCaster.cast(item, ExampleQueries.Item)
  end

  test "ResultCaster leaves primitive result types unchanged" do
    assert {:ok, true} = ResultCaster.cast(true, :boolean)
    assert {:ok, "ok"} = ResultCaster.cast("ok", :string)
    assert {:ok, :raw} = ResultCaster.cast(:raw, nil)
  end

  test "Identified and Deleted keep only id when casting from a richer map" do
    source = %{id: 9, name: "Widget", extra: true}

    assert {:ok, %Dobro.App.Types.Identified{id: 9}} =
             ResultCaster.cast(source, Dobro.App.Types.Identified)

    assert {:ok, %Dobro.App.Types.Deleted{id: 9}} =
             ResultCaster.cast(source, Dobro.App.Types.Deleted)
  end

  test "pipeline finalize without a result type still returns the raw map" do
    {:ok, query} = ExampleQueries.Untyped.new(%{})

    assert {:ok, %{ok: true}} =
             %Pipeline{state: %{result: %{ok: true}}, input: query, errors: []}
             |> Dobro.App.QueryHandler.Pipeline.finalize(:result)
  end
end
