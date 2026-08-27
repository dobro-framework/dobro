defmodule Dobro.Runtime.Command.ExecutionStrategy.Actor do
  @moduledoc """
  Routes all commands through an aggregate actor GenServer.

  Commands must carry an identity. Use `:actor_when_identified` when some
  commands are creates without identity.
  """

  @behaviour Dobro.App.Command.ExecutionStrategy

  alias Dobro.App.CommandHandler.Helpers
  alias Dobro.App.Command.Strategy
  alias Dobro.Error
  alias Dobro.Pipeline
  alias Dobro.Runtime.{AggregateActor, AggregateSupervisor}

  import Dobro.Pipeline

  @impl true
  def execute(%Pipeline{} = pipeline, call_fn, aggregate_module, _opts, %Strategy{} = strategies) do
    if pipeline.state.identity do
      invoke_actor(pipeline, call_fn, aggregate_module, strategies)
    else
      merge_errors(
        pipeline,
        Error.new(:execution_strategy_requires_identity,
          description: "execution_strategy: :actor requires a command identity"
        )
      )
    end
  end

  defp invoke_actor(%Pipeline{} = pipeline, call_fn, aggregate_module, strategies) do
    contract = Helpers.contract_from_pipeline(pipeline)

    case AggregateSupervisor.ensure_started(
           aggregate_module,
           pipeline.config.tenant,
           pipeline.state.identity,
           persistence_strategy: persistence_shorthand(strategies)
         ) do
      {:ok, pid} ->
        case AggregateActor.execute(
               pid,
               call_fn,
               contract,
               pipeline.input.message_identity,
               strategies
             ) do
          {:ok, result} ->
            put_in(pipeline.state, %{
              pipeline.state
              | unit_of_work: %{pipeline.state.unit_of_work | aggregate: result.value},
                events: result.events ++ pipeline.state.events
            })

          {:error, error} ->
            merge_errors(pipeline, error)
        end

      {:error, error} ->
        merge_errors(pipeline, error)
    end
  end

  defp persistence_shorthand(%Strategy{persistence: {Dobro.App.Command.PersistenceStrategy.Stateful, _}}),
    do: :stateful

  defp persistence_shorthand(%Strategy{
         persistence: {Dobro.App.Command.PersistenceStrategy.EventSourced, _}
       }),
       do: :event_sourced

  defp persistence_shorthand(%Strategy{persistence: {mod, _}}), do: mod
end
