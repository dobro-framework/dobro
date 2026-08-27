defmodule Dobro.Cqrs.Config do
  @moduledoc """
  Configuration for the CQRS application layer.

  ## Strategy keys

  | Key | Default | Description |
  |-----|---------|-------------|
  | `:execution_strategy` | `:actor_when_identified` | How aggregate functions run |
  | `:persistence_strategy` | `:stateful` | How state and events are stored |
  | `:event_delivery_strategy` | `:none` | How events reach subscribers |

  When using `dobro_runtime` for identified aggregates and PubSub or outbox delivery,
  configure strategy keys and `config :dobro_runtime, pubsub:` (and optionally `outbox_relay:`).
  """

  alias Dobro.App.Command.Strategy

  @doc """
  Returns the configured execution strategy shorthand or module tuple.
  """
  @spec execution_strategy() :: term()
  def execution_strategy, do: Strategy.lookup(:execution_strategy, [])

  @doc """
  Returns the configured persistence strategy shorthand or module tuple.
  """
  @spec persistence_strategy() :: term()
  def persistence_strategy, do: Strategy.lookup(:persistence_strategy, [])

  @doc """
  Returns the configured event delivery strategy shorthand or module tuple.
  """
  @spec event_delivery_strategy() :: term()
  def event_delivery_strategy, do: Strategy.lookup(:event_delivery_strategy, [])
end
