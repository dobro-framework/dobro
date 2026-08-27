defmodule Dobro.App.Command.EventDeliveryStrategy do
  @moduledoc """
  Behaviour for domain event delivery strategies.

  Delivery strategies may stage work inside a database transaction (`stage/3`)
  and publish events after commit (`deliver/3`).

  Whether `stage/3` must share a transaction with local persist is declared via
  `transactional_stage?/0`. Combined with WriteRepo `transactional?/0`,
  `Dobro.App.Command.Commit` decides transaction boundaries.
  """

  @callback stage([term()], map(), keyword()) :: :ok | {:error, term()}
  @callback deliver([term()], map(), keyword()) :: :ok | {:error, term()}

  @doc """
  When true, `stage/3` writes to the local DB and must run in a Postgres
  transaction (e.g. outbox insert).

  Optional — defaults to true when not implemented. PubSub/None return false
  because they do not stage durable work.
  """
  @callback transactional_stage?() :: boolean()
  @optional_callbacks transactional_stage?: 0

  @doc "Normalises event delivery strategy configuration to `{module, opts}`."
  @spec resolve(term()) :: {module(), keyword()}
  def resolve(:none), do: {__MODULE__.None, []}

  def resolve(:outbox) do
    if Code.ensure_loaded?(Dobro.Runtime.Command.EventDeliveryStrategy.Outbox) do
      {Dobro.Runtime.Command.EventDeliveryStrategy.Outbox, []}
    else
      raise ArgumentError, ":outbox event delivery strategy requires dobro_runtime"
    end
  end

  def resolve(:pubsub) do
    if Code.ensure_loaded?(Dobro.Runtime.Command.EventDeliveryStrategy.PubSub) do
      {Dobro.Runtime.Command.EventDeliveryStrategy.PubSub, []}
    else
      raise ArgumentError,
            ":pubsub event delivery strategy requires dobro_runtime"
    end
  end

  def resolve({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  def resolve(module) when is_atom(module), do: {module, []}

  def resolve(strategy),
    do: raise(ArgumentError, "invalid event delivery strategy: #{inspect(strategy)}")
end
