defmodule Dobro.App.Command.ExecutionStrategy.ActorWhenIdentifiedTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Command.ExecutionStrategy.ActorWhenIdentified
  alias Dobro.App.Command.Strategy
  alias Dobro.App.CommandHandler.State
  alias Dobro.Error
  alias Dobro.Pipeline

  test "returns a runtime_required error for commands with identity" do
    pipeline =
      Pipeline.new(
        state: %State{identity: %{id: 1}},
        input: %{},
        config: %{tenant: nil, opts: []}
      )

    strategies = Strategy.resolve(nil, [])

    result =
      ActorWhenIdentified.execute(pipeline, :create, MyApp.Aggregate, [], strategies)

    assert {:error, [%Error{reason: :runtime_required} | _]} = Pipeline.finalize(result)
  end
end
