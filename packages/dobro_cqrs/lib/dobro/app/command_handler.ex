defmodule Dobro.App.CommandHandler do
  @moduledoc """
  Provides CommandHandler capabilities
  """
  alias Dobro.App.Command.Strategy
  alias Dobro.App.ExecutionContext
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork
  # alias Phoenix.PubSub
  # @callback execute(term()) :: {:ok, term()} | {:error, term()}
  @callback execute(term(), ExecutionContext.t()) :: {:ok, term()} | {:error, term()}

  defmodule State do
    @moduledoc """
    State for the CommandHandler
    - unit_of_work: The unit of work to be committed
    - events: The events to be emitted
    - result: The result of the command
    - workspace: The workspace of the command, which can be used to store intermediate results
    - contract: The contract of the command
    - contract_attrs: Plain attrs map for contract construction (enriched by `:before_contract` middleware)
    """
    use TypedStruct

    typedstruct do
      # unit_of_work: Only used for direct invocation of the aggregate
      field :unit_of_work, UnitOfWork.t(), default: %UnitOfWork{}
      field :events, list(term()), default: []
      field :result, term(), default: nil
      field :workspace, map(), default: %{}
      field :contract, map(), default: %{}
      field :contract_attrs, map(), default: %{}
      field :identity, map(), default: nil
      field :version, integer(), default: nil
      field :opts, list(), default: []
    end
  end

  defmacro __using__(opts \\ []) do
    aggregate_module = Keyword.get(opts, :aggregate)
    strategy_opts = Keyword.take(opts, Strategy.strategy_keys())
    middleware = expand_middleware_entries(Keyword.get(opts, :middleware, []), __CALLER__)

    quote location: :keep do
      @behaviour Dobro.App.CommandHandler
      @aggregate_module unquote(aggregate_module)
      @handler_strategy_opts unquote(Macro.escape(strategy_opts))
      @handler_middleware unquote(middleware)

      def __handler_strategy_opts__, do: @handler_strategy_opts
      def __handler_middleware__, do: @handler_middleware

      import Dobro.Pipeline, except: [finalize: 1, finalize: 2]
      alias Dobro.Pipeline

      import Dobro.App.CommandHandler,
        only: [
          handle: 2,
          handle: 3,
          handle: 4,
          execute_command: 2,
          execute_aggregate: 2,
          execute_aggregate: 3
        ]

      # Full-arity execute_* stay on Pipeline for strategies/tests; handlers use macros above.
      import Dobro.App.CommandHandler.Pipeline,
        except: [execute_command: 4, execute_aggregate: 3, execute_aggregate: 4, execute_aggregate: 5]
    end
  end

  @doc """
  Runs the standard command path using the handler's `@aggregate_module` and `__MODULE__`.
  """
  defmacro execute_command(pipeline, call_fn) do
    quote do
      Dobro.App.CommandHandler.Pipeline.execute_command(
        unquote(pipeline),
        unquote(call_fn),
        @aggregate_module,
        __MODULE__
      )
    end
  end

  @doc """
  Runs strategy resolution and aggregate invocation using `@aggregate_module` and `__MODULE__`.
  """
  defmacro execute_aggregate(pipeline, call_fn) do
    quote do
      Dobro.App.CommandHandler.Pipeline.execute_aggregate(
        unquote(pipeline),
        unquote(call_fn),
        @aggregate_module,
        [],
        __MODULE__
      )
    end
  end

  defmacro execute_aggregate(pipeline, call_fn, opts) do
    quote do
      Dobro.App.CommandHandler.Pipeline.execute_aggregate(
        unquote(pipeline),
        unquote(call_fn),
        @aggregate_module,
        unquote(opts),
        __MODULE__
      )
    end
  end

  @doc """
  Defines a command handler for a given command module.

  ## Options

  - `contract:` — domain contract module (`Module.new(contract_attrs)`), or an arity-2
    function `(contract_attrs, execution_context) -> {:ok, contract} | {:error, term}`
  - `identity_fn:` — `(identity, execution_context) -> {:ok, identity} | {:error, term}`
  - `transform_result:` — `(aggregate) -> result`
  - `middleware:` — appends to handler-level `middleware:` from `use CommandHandler`
  - `if:` — specifications to check before execute

  ## Examples

  ```elixir
  handle CommandModule, :do_something, contract: DoSomethingDomainContract

  handle CreateCase, :create,
    contract: &create_contract/2,
    transform_result: fn funeral_case -> %{id: funeral_case.id} end

  handle SetCurrentOffice, :set_current_office,
    identity_fn: &ensure_self_identity/2,
    contract: User.SetCurrentOffice
  ```
  """
  defmacro handle(command_module, call_fn, opts \\ [])

  defmacro handle(command_module, call_fn, opts) when is_atom(call_fn) and is_list(opts) do
    if Keyword.get(opts, :execution_strategy) == :actor do
      assert_command_identity!(command_module)
    end

    opts =
      case Keyword.fetch(opts, :middleware) do
        {:ok, entries} ->
          Keyword.put(opts, :middleware, expand_middleware_entries(entries, __CALLER__))

        :error ->
          opts
      end

    quote do
      def execute(%unquote(command_module){} = command, execution_context) do
        opts =
          Dobro.App.CommandHandler.merge_middleware_opts(
            unquote(opts),
            __handler_middleware__()
          )

        pipeline(command, execution_context, opts)
        |> execute_command(unquote(call_fn))
      end

      def execute(%unquote(command_module){} = command) do
        opts =
          Dobro.App.CommandHandler.merge_middleware_opts(
            unquote(opts),
            __handler_middleware__()
          )

        pipeline(command, opts)
        |> execute_command(unquote(call_fn))
      end
    end
  end

  defmacro handle(command_module, command_var, do: block) do
    quote do
      def execute(%unquote(command_module){} = unquote(command_var)) do
        unquote(block)
      end
    end
  end

  defmacro handle(command_module, command_var, execution_context_var, do: block) do
    quote do
      def execute(
            %unquote(command_module){} = unquote(command_var),
            unquote(execution_context_var)
          ) do
        unquote(block)
      end
    end
  end

  @doc false
  def merge_middleware_opts(opts, handler_middleware) when is_list(opts) do
    handle_middleware = Keyword.get(opts, :middleware, [])
    Keyword.put(opts, :middleware, List.wrap(handler_middleware) ++ List.wrap(handle_middleware))
  end

  defp expand_middleware_entries(entries, env) when is_list(entries) do
    Enum.map(entries, &expand_middleware_entry(&1, env))
  end

  defp expand_middleware_entries(nil, _env), do: []

  defp expand_middleware_entry({:__aliases__, _, _} = alias, env) do
    Macro.expand(alias, env)
  end

  defp expand_middleware_entry({{:__aliases__, _, _} = alias, opts}, env) when is_list(opts) do
    {Macro.expand(alias, env), opts}
  end

  defp expand_middleware_entry(entry, _env), do: entry

  defp assert_command_identity!(command_module) do
    unless Code.ensure_loaded?(command_module) and
             function_exported?(command_module, :__identity__, 0) do
      raise CompileError,
            description:
              "command #{inspect(command_module)} requires identity for execution_strategy: :actor"
    end
  end
end
