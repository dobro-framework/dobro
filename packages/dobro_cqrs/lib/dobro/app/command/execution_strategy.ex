defmodule Dobro.App.Command.ExecutionStrategy do
  @moduledoc """
  Behaviour for command execution strategies.

  Execution strategies run the aggregate domain function and update pipeline state.
  Persistence and event delivery are handled separately by `Dobro.App.Command.Commit`.
  """

  alias Dobro.App.Command.Strategy
  alias Dobro.Pipeline

  @callback execute(
              Pipeline.t(),
              atom(),
              module(),
              keyword(),
              Strategy.t()
            ) :: Pipeline.t()

  @doc "Normalises execution strategy configuration to `{module, opts}`."
  @spec resolve(term()) :: {module(), keyword()}
  def resolve(:inline), do: {__MODULE__.Inline, []}
  def resolve(:actor_when_identified), do: {__MODULE__.ActorWhenIdentified, []}

  def resolve(:actor) do
    if Code.ensure_loaded?(Dobro.Runtime.Command.ExecutionStrategy.Actor) do
      {Dobro.Runtime.Command.ExecutionStrategy.Actor, []}
    else
      raise ArgumentError,
            ":actor execution strategy requires dobro_runtime"
    end
  end

  def resolve({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  def resolve(module) when is_atom(module), do: {module, []}

  def resolve(strategy),
    do: raise(ArgumentError, "invalid execution strategy: #{inspect(strategy)}")
end
