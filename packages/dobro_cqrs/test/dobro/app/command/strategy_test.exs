defmodule Dobro.App.Command.StrategyTest do
  use ExUnit.Case, async: false

  alias Dobro.App.Command.{
    EventDeliveryStrategy,
    ExecutionStrategy,
    PersistenceStrategy,
    Strategy
  }

  setup do
    on_exit(fn ->
      Application.delete_env(:dobro_cqrs, :execution_strategy)
      Application.delete_env(:dobro_cqrs, :persistence_strategy)
      Application.delete_env(:dobro_cqrs, :event_delivery_strategy)
    end)

    :ok
  end

  test "resolve/2 uses hardcoded defaults when nothing is configured" do
    Application.delete_env(:dobro_cqrs, :execution_strategy)

    strategies = Strategy.resolve(nil, [])

    assert strategies.execution == ExecutionStrategy.resolve(:actor_when_identified)
    assert strategies.persistence == PersistenceStrategy.resolve(:stateful)
    assert strategies.event_delivery == EventDeliveryStrategy.resolve(:none)
  end

  test "resolve/2 honours explicit strategy configuration" do
    Application.put_env(:dobro_cqrs, :execution_strategy, :inline)
    Application.put_env(:dobro_cqrs, :persistence_strategy, :stateful)
    Application.put_env(:dobro_cqrs, :event_delivery_strategy, :none)

    strategies = Strategy.resolve(nil, [])

    assert strategies.execution == ExecutionStrategy.resolve(:inline)
    assert strategies.persistence == PersistenceStrategy.resolve(:stateful)
    assert strategies.event_delivery == EventDeliveryStrategy.resolve(:none)
  end

  test "resolve/2 prefers handle options over application config" do
    Application.put_env(:dobro_cqrs, :execution_strategy, :inline)

    strategies = Strategy.resolve(nil, execution_strategy: :actor_when_identified)

    assert strategies.execution == ExecutionStrategy.resolve(:actor_when_identified)
  end

  test "resolve/2 supports event_sourced persistence" do
    strategies = Strategy.resolve(nil, persistence_strategy: :event_sourced)

    assert strategies.persistence == PersistenceStrategy.resolve(:event_sourced)
  end
end
