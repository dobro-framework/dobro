defmodule Dobro.App.QueryHandler do
  @moduledoc """
  Behaviour and macros for **application query handlers**.

  Handlers validate scope, convert query payloads to DTOs, and call read repo
  functions. The second argument to `handle/2` is a **repo function atom** —
  typically the `:as` name from an infrastructure `defquery`, or a custom
  function on the read repo adapter.

  See the [dobro_cqrs README](readme.html) for how application queries connect
  to infrastructure queries in `dobro_ecto`.
  """
  alias Dobro.App.ExecutionContext

  @callback execute(term()) :: {:ok, term()} | {:error, term()}
  @callback execute(term(), ExecutionContext.t()) :: {:ok, term()} | {:error, term()}

  alias Dobro.App.DataTransfer.DTO

  defmodule State do
    @moduledoc """
    The QueryHandler state
    - result: The final result of the query
    - workspace: The workspace of the query, which can be used to store intermediate results
    """
    defstruct result: %{}, workspace: %{}
  end

  defmacro __using__(opts \\ []) do
    repo = Keyword.get(opts, :repo)

    repo_fun =
      if repo do
        quote do
          def repo(opts \\ []), do: unquote(repo).adapter(opts)
        end
      else
        quote do
          def repo(_opts \\ []), do: nil
        end
      end

    quote location: :keep do
      @behaviour Dobro.App.QueryHandler

      Module.register_attribute(__MODULE__, :query_handles, accumulate: true)
      @before_compile {Dobro.App.QueryHandler.Wiring, :__before_compile__}

      import Dobro.App.QueryHandler, only: [handle: 2, handle: 3, handle: 4]
      import Dobro.App.QueryHandler.Helpers
      import Dobro.App.QueryHandler.Pipeline, except: [call: 3, call: 4]
      import Dobro.Pipeline, except: [finalize: 1, finalize: 2]
      alias Dobro.Pipeline

      @query_handler_repo unquote(repo)

      unquote(repo_fun)

      defp call(pipeline, repo_fn, opts \\ []),
        do: Dobro.App.QueryHandler.Pipeline.call(pipeline, repo_fn, repo(), opts)

      def execute(_input_query) do
        raise "execute/1 not implemented for #{__MODULE__}"
      end

      def execute(%_{} = input_query, %ExecutionContext{} = _context) do
        execute(input_query)
      end

      defoverridable(execute: 1, execute: 2)
    end
  end

  defmodule Helpers do
    @moduledoc """
    Input preparation and result emission helpers for query handlers.
    """

    alias Dobro.App.ResultCaster
    alias Dobro.Pipeline

    @doc "Converts a handler result to DTOs when successful."
    def emit({:ok, result}), do: {:ok, DTO.to_dto(result)}
    def emit({:error, result}), do: {:error, result}
    def emit(result), do: result

    @doc """
    Finalizes a query pipeline and casts the payload to the query's `result` type.
    """
    def finalize(%Pipeline{input: %mod{}} = pipeline, :result) do
      case Pipeline.finalize(pipeline, :result) do
        {:ok, result} -> ResultCaster.cast_message_result(mod, result)
        other -> other
      end
    end

    def finalize(%Pipeline{} = pipeline, keys), do: Pipeline.finalize(pipeline, keys)
    def finalize(%Pipeline{} = pipeline), do: Pipeline.finalize(pipeline)

    @doc "Enriches query input with values from the execution context."
    def prepare_input(%_{} = input, provide, context) do
      prepare_input(Map.from_struct(input), provide, context)
    end

    def prepare_input(%{} = input, provide, _context) when provide == [] do
      input
    end

    def prepare_input(%{} = input, provide, context) do
      provide
      |> Enum.reduce(input, fn
        :tenant_id, acc -> Map.put(acc, :tenant_id, context.tenant.id)
        :tenant_identifier, acc -> Map.put(acc, :tenant_identifier, context.tenant.identifier)
        key, _ -> raise "Cannot provide: #{key}"
      end)
    end
  end

  defmacro handle(query_module, repo_fn) do
    quote location: :keep do
      @query_handles {unquote(query_module), unquote(repo_fn)}

      def execute(%unquote(query_module){} = query) do
        pipeline(query)
        |> call(unquote(repo_fn))
        |> finalize(:result)
      end

      def execute(%unquote(query_module){} = query, %ExecutionContext{} = execution_context) do
        pipeline(query, execution_context)
        |> call(unquote(repo_fn))
        |> finalize(:result)
      end
    end
  end

  defmacro handle(query_module, query_var, do: block) do
    quote location: :keep do
      def execute(%unquote(query_module){} = unquote(query_var)) do
        unquote(block)
      end

      def execute(
            %unquote(query_module){} = unquote(query_var),
            %ExecutionContext{} = execution_context
          ) do
        execute(unquote(query_var))
      end
    end
  end

  defmacro handle(query_module, query_var, execution_context, do: block) do
    quote location: :keep do
      def execute(
            %unquote(query_module){} = unquote(query_var),
            %ExecutionContext{} = unquote(execution_context)
          ) do
        unquote(block)
      end
    end
  end
end
