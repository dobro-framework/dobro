defmodule Dobro.PipelineTest do
  use ExUnit.Case, async: true

  alias Dobro.Error
  alias Dobro.Pipeline

  test "step/2 continues with the returned pipeline on {:ok, pipeline}" do
    pipeline = Pipeline.new(state: %{value: 1}, input: %{}, config: %{})

    result =
      pipeline
      |> Pipeline.step(fn p -> {:ok, %{p | input: %{enriched: true}}} end)
      |> Pipeline.finalize()

    assert {:ok, %{input: %{enriched: true}}} = result
  end

  test "step/2 adds an error and short-circuits on {:error, error}" do
    pipeline = Pipeline.new(state: %{value: 1}, input: %{}, config: %{})
    error = Error.new(:invalid, path: :action, description: "nope")

    result =
      pipeline
      |> Pipeline.step(fn _ -> {:error, error} end)
      |> Pipeline.step(fn p -> {:ok, %{p | input: %{should_not_run: true}}} end)
      |> Pipeline.finalize()

    assert {:error, [%Error{reason: :invalid, path: :action}]} = result
  end

  test "step/2 is a no-op when the pipeline already has errors" do
    pipeline = %{
      Pipeline.new(state: %{}, input: %{}, config: %{})
      | errors: [Error.new(:already_failed)]
    }

    result =
      Pipeline.step(pipeline, fn _ ->
        flunk("step fun should not run when pipeline already has errors")
      end)

    assert result.errors == pipeline.errors
  end
end
