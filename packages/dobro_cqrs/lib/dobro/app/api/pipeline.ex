defmodule Dobro.App.Api.Pipeline do
  @moduledoc """
  Pipeline module to execute middleware pipelines.

  Phases:

  - `:before_run` — mutate-style hooks on `PipelineContext` (via `Dobro.Pipeline.run_hooks/2`)
  - `:run` — wrap-style onion middleware (`call/3` + `next.()`) around the route `run`
  - `:after_run` — mutate-style hooks after the onion (currently unused; reserved)
  """

  alias Dobro.App.ExecutionContext
  alias Dobro.Pipeline

  defmodule PipelineContext do
    @moduledoc """
    Pipeline Context holds execution information
    """
    use TypedStruct

    typedstruct do
      field :name, tuple() | nil, default: nil
      field :type, atom() | nil, default: nil
      field :policy, atom() | nil, default: nil
      field :middleware, list() | nil, default: []
      field :before_run, list(), default: []
      field :after_run, list(), default: []
      field :args, any() | nil, default: nil
      field :run, any() | nil, default: nil
    end

    def new(%__MODULE__{} = struct), do: struct

    def new(attrs) do
      struct(__MODULE__, attrs)
    end
  end

  def execute(
        %PipelineContext{middleware: middleware, run: run} = pipeline_context,
        %ExecutionContext{} = execution_context
      )
      when is_list(middleware) and is_function(run) do
    pipeline_context = run_before_hooks(pipeline_context)

    result = run_onion(pipeline_context, execution_context)

    _ = run_after_hooks(pipeline_context, result)

    result
  end

  def execute(pipeline_context, execution_context) do
    raise "Invalid pipeline execution: #{inspect(pipeline_context)} #{inspect(execution_context)}"
  end

  defp run_before_hooks(%PipelineContext{before_run: hooks} = pipeline_context)
       when is_list(hooks) and hooks != [] do
    wrapped =
      %Pipeline{state: pipeline_context, errors: []}
      |> Pipeline.run_hooks(Enum.map(hooks, &context_hook/1))

    wrapped.state
  end

  defp run_before_hooks(pipeline_context), do: pipeline_context

  # after_run reserved — mutate-style hooks would need a result-carrying state.
  # Keep the phase call site; no-op until callers supply after_run hooks.
  defp run_after_hooks(%PipelineContext{after_run: hooks}, result)
       when is_list(hooks) and hooks != [] do
    result
  end

  defp run_after_hooks(_pipeline_context, result), do: result

  defp context_hook(fun) when is_function(fun, 1) do
    fn %Pipeline{state: %PipelineContext{} = ctx} = pipeline ->
      %{pipeline | state: fun.(ctx)}
    end
  end

  defp run_onion(
         %PipelineContext{middleware: middleware, run: run} = pipeline_context,
         %ExecutionContext{} = execution_context
       ) do
    Enum.reverse(middleware)
    |> Enum.reduce(run, fn mod, acc ->
      fn -> mod.call(pipeline_context, execution_context, acc) end
    end)
    |> then(& &1.())
  end
end
