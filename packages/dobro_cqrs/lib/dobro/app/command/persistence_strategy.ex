defmodule Dobro.App.Command.PersistenceStrategy do
  @moduledoc """
  Behaviour for command persistence strategies.

  Persistence strategies store aggregate state and domain events. Transaction
  boundaries are orchestrated by `Dobro.App.Command.Commit` based on whether
  persist is transactional (DB) and whether event delivery needs transactional
  staging (e.g. outbox).
  """

  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  @type tenant :: term()
  @type message_identity :: term()

  @callback persist(
              UnitOfWork.t(),
              [term()],
              tenant(),
              message_identity(),
              keyword()
            ) :: {:ok, UnitOfWork.t(), [term()]} | {:error, term()}

  @doc """
  When true, persist writes to the local DB and can join a Postgres transaction.

  Optional — defaults to true. Stateful strategies should delegate to the resolved
  WriteRepo (`transactional?/0`); remote HTTP adapters return false.
  """
  @callback transactional_persist?(
              UnitOfWork.t(),
              [term()],
              tenant(),
              keyword()
            ) :: boolean()
  @optional_callbacks transactional_persist?: 4

  @doc "Normalises persistence strategy configuration to `{module, opts}`."
  @spec resolve(term()) :: {module(), keyword()}
  def resolve(:stateful), do: {__MODULE__.Stateful, []}

  def resolve(:event_sourced) do
    {Dobro.App.Command.PersistenceStrategy.EventSourced, []}
  end

  def resolve({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  def resolve(module) when is_atom(module), do: {module, []}

  def resolve(strategy),
    do: raise(ArgumentError, "invalid persistence strategy: #{inspect(strategy)}")
end
