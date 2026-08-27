defmodule Dobro.App.Api.Pipeline do
  @moduledoc """
  Pipeline module to execute middleware pipelines
  """

  alias Dobro.App.ExecutionContext

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
    Enum.reverse(middleware)
    |> Enum.reduce(run, fn mod, acc ->
      fn -> mod.call(pipeline_context, execution_context, acc) end
    end)
    |> (& &1.()).()
  end

  def execute(pipeline_context, execution_context) do
    raise "Invalid pipeline execution: #{inspect(pipeline_context)} #{inspect(execution_context)}"
  end
end
