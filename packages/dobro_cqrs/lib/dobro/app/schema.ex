defmodule Dobro.App.Schema do
  @moduledoc """
  Macro for App (Command/Query) schemas
  """

  alias Dobro.Pipeline

  defmodule State do
    @moduledoc "Internal pipeline state for command and query schema casting."
    defstruct value: %{}
  end

  defmacro __using__(opts) do
    defaults = Keyword.get(opts, :defaults, [])

    quote do
      use Dobro.Schema,
        defaults: unquote(defaults)

      import Dobro.State
      import Dobro.Pipeline

      def pipeline(%{} = cmd_or_query, input) do
        config = %{schema_module: __MODULE__}
        state = %State{value: cmd_or_query}
        Pipeline.new(state: state, input: input, config: config)
      end

      @before_compile Dobro.App.Schema

      def new(args) do
        pipeline(%{}, args)
        |> assign_all()
        |> cast()
      end

      defoverridable new: 1
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def cast(%Pipeline{} = pipeline) do
        pipeline
        |> validate(__schema__())
        |> bind(fn pipeline ->
          put_in(pipeline.state, %{
            pipeline.state
            | value: struct(__MODULE__, pipeline.state.value)
          })
        end)
        |> finalize(:value)
      end
    end
  end
end
