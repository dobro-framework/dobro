defmodule Dobro.App.Command.Strategy do
  @moduledoc """
  Resolved command execution, persistence, and event delivery strategies.

  Strategies are resolved from handle options, handler options, application config,
  and hardcoded defaults.
  """

  alias Dobro.App.Command.{
    EventDeliveryStrategy,
    ExecutionStrategy,
    PersistenceStrategy
  }

  @strategy_keys [:execution_strategy, :persistence_strategy, :event_delivery_strategy]

  defstruct execution: nil,
            persistence: nil,
            event_delivery: nil

  @type t :: %__MODULE__{
          execution: {module(), keyword()},
          persistence: {module(), keyword()},
          event_delivery: {module(), keyword()}
        }

  @doc """
  Resolves all three strategies for a command handle.

  `handler_module` may be `nil` when handler-level overrides are not needed.
  `handle_opts` are the options passed to `handle/3`.
  """
  @spec resolve(module() | nil, keyword()) :: t()
  def resolve(handler_module \\ nil, handle_opts \\ []) do
    handler_opts = handler_strategy_opts(handler_module)
    merged_opts = Keyword.merge(handler_opts, handle_opts)

    %__MODULE__{
      execution: ExecutionStrategy.resolve(lookup(:execution_strategy, merged_opts)),
      persistence: PersistenceStrategy.resolve(lookup(:persistence_strategy, merged_opts)),
      event_delivery: EventDeliveryStrategy.resolve(lookup(:event_delivery_strategy, merged_opts))
    }
  end

  @doc false
  def strategy_keys, do: @strategy_keys

  @doc false
  def handler_strategy_opts(nil), do: []

  def handler_strategy_opts(handler_module) do
    if function_exported?(handler_module, :__handler_strategy_opts__, 0) do
      handler_module.__handler_strategy_opts__()
    else
      []
    end
  end

  @doc false
  @spec lookup(atom(), keyword()) :: term()
  def lookup(key, opts) do
    cond do
      Keyword.has_key?(opts, key) ->
        Keyword.fetch!(opts, key)

      not is_nil(Application.get_env(:dobro_cqrs, key)) ->
        Application.get_env(:dobro_cqrs, key)

      true ->
        default(key)
    end
  end

  defp default(:execution_strategy), do: :actor_when_identified
  defp default(:persistence_strategy), do: :stateful
  defp default(:event_delivery_strategy), do: :none
end
