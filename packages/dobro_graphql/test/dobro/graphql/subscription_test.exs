defmodule Dobro.Graphql.SubscriptionTest do
  use ExUnit.Case, async: true

  defmodule Item do
    use Dobro.Schema

    schema do
      field :id, :id
      field :status, :string
    end
  end

  defmodule ProgressArgs do
    use Dobro.Schema

    schema do
      field :id, :id, required: true
    end
  end

  defmodule GetItem do
    def __result__, do: Dobro.Graphql.SubscriptionTest.Item
    def __schema__, do: []
  end

  defmodule Topics do
    def progress_topic(%{id: id}), do: "item:#{id}"
  end

  defmodule ItemsPort do
    use Dobro.Spec.Port

    @callback ping() :: :ok
  end

  defmodule ProgressApi do
    use Dobro.App.Api,
      port: Dobro.Graphql.SubscriptionTest.ItemsPort,
      context: {Dobro.Graphql.SubscriptionTest, :items},
      surfaces: [:graphql]

    def ping, do: :ok

    subscription :progress,
      args: Dobro.Graphql.SubscriptionTest.ProgressArgs,
      result: Dobro.Graphql.SubscriptionTest.GetItem,
      topic: {Dobro.Graphql.SubscriptionTest.Topics, :progress_topic}

    subscription :updated,
      args: Dobro.Graphql.SubscriptionTest.ProgressArgs,
      result: Dobro.Graphql.SubscriptionTest.Item,
      topic: {Dobro.Graphql.SubscriptionTest.Topics, :progress_topic}
  end

  defmodule Notation do
    use Dobro.Graphql.Schema,
      apis: [Dobro.Graphql.SubscriptionTest.ProgressApi],
      surfaces: [:graphql]
  end

  defmodule Schema do
    use Absinthe.Schema
    use Dobro.Graphql.Schema.Root, modules: [Notation]

    query do
      field :health, :string do
        resolve(fn _, _ -> {:ok, "ok"} end)
      end
    end

    object :items_get_item_result do
      field :id, :id
      field :status, :string
    end
  end

  test "a query result is reused and the topic function receives the arguments" do
    field = Schema.__absinthe_type__(:subscription).fields.progress

    assert field.type == :items_get_item_result
    config = Absinthe.Type.function(field, :config)
    assert {:ok, topic: "item:7"} = config.(%{id: "7"}, %{})
  end

  test "a contract result is emitted as an object" do
    field = Schema.__absinthe_type__(:subscription).fields.updated

    assert field.type == :items_item
    assert %Absinthe.Type.Object{identifier: :items_item} = Schema.__absinthe_type__(:items_item)
  end
end
