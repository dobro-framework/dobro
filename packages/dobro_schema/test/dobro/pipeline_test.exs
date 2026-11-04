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

  describe "run_hooks/2" do
    test "runs hooks in order" do
      pipeline = Pipeline.new(state: %{n: 0}, input: %{}, config: %{})

      result =
        Pipeline.run_hooks(pipeline, [
          fn p -> put_in(p.state.n, p.state.n + 1) end,
          fn p -> put_in(p.state.n, p.state.n * 10) end
        ])

      assert result.state.n == 10
    end

    test "short-circuits when the pipeline already has errors" do
      pipeline = %{
        Pipeline.new(state: %{n: 0}, input: %{}, config: %{})
        | errors: [Error.new(:already_failed)]
      }

      result =
        Pipeline.run_hooks(pipeline, [
          fn _ -> flunk("hook should not run when pipeline already has errors") end
        ])

      assert result.state.n == 0
      assert [%Error{reason: :already_failed}] = result.errors
    end

    test "short-circuits after a hook adds errors" do
      pipeline = Pipeline.new(state: %{n: 0}, input: %{}, config: %{})

      result =
        Pipeline.run_hooks(pipeline, [
          fn p -> Pipeline.add_error(p, Error.new(:boom)) end,
          fn _ -> flunk("later hook should not run") end
        ])

      assert [%Error{reason: :boom}] = result.errors
    end
  end
end
