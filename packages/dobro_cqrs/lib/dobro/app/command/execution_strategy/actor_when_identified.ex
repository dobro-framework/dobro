defmodule Dobro.App.Command.ExecutionStrategy.ActorWhenIdentified do
  @moduledoc """
  Default execution strategy.

  Uses `:inline` when the command has no identity and routes identified commands
  through `Dobro.Runtime.Command.ExecutionStrategy.Actor` when `dobro_runtime` is present.
  """

  @behaviour Dobro.App.Command.ExecutionStrategy

  @compile {:no_warn_undefined, {Dobro.Runtime.Command.ExecutionStrategy.Actor, :execute, 5}}

  alias Dobro.App.Command.ExecutionStrategy.Inline
  alias Dobro.App.Command.Strategy
  alias Dobro.Error
  alias Dobro.Pipeline

  import Dobro.Pipeline

  @impl true
  def execute(%Pipeline{} = pipeline, call_fn, aggregate_module, opts, %Strategy{} = strategies) do
    if pipeline.state.identity do
      execute_via_actor(pipeline, call_fn, aggregate_module, strategies)
    else
      Inline.execute(pipeline, call_fn, aggregate_module, opts, strategies)
    end
  end

  defp execute_via_actor(pipeline, call_fn, aggregate_module, strategies) do
    if Code.ensure_loaded?(Dobro.Runtime.Command.ExecutionStrategy.Actor) do
      Dobro.Runtime.Command.ExecutionStrategy.Actor.execute(
        pipeline,
        call_fn,
        aggregate_module,
        [],
        strategies
      )
    else
      merge_errors(
        pipeline,
        Error.new(:runtime_required,
          description:
            "Commands with identity require dobro_runtime. " <>
              "Add {:dobro_runtime, \"~> 0.1\"} and configure " <>
              "config :dobro_cqrs, execution_strategy: :actor_when_identified"
        )
      )
    end
  end
end
