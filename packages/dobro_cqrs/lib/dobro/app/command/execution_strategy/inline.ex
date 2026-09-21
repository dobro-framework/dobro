defmodule Dobro.App.Command.ExecutionStrategy.Inline do
  @moduledoc """
  Runs aggregate domain functions in the caller's process.

  Changes are committed through `Dobro.App.Command.Commit` after a successful
  domain invocation.
  """

  @behaviour Dobro.App.Command.ExecutionStrategy

  alias Dobro.App.Command.Commit
  alias Dobro.App.CommandHandler.Pipeline, as: CommandPipeline
  alias Dobro.App.Command.Strategy
  alias Dobro.Pipeline

  @impl true
  def execute(%Pipeline{} = pipeline, call_fn, aggregate_module, opts, %Strategy{} = strategies) do
    pipeline
    |> CommandPipeline.invoke_direct(call_fn, aggregate_module, opts)
    |> Commit.apply_to_pipeline(strategies)
  end
end
