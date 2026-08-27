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
    """
    use TypedStruct

    typedstruct do
      # unit_of_work: Only used for direct invocation of the aggregate
      field :unit_of_work, UnitOfWork.t(), default: %UnitOfWork{}
      field :events, list(term()), default: []
      field :result, term(), default: nil
      field :workspace, map(), default: %{}
      field :contract, map(), default: %{}
      field :identity, map(), default: nil
      field :version, integer(), default: nil
      field :opts, list(), default: []
    end
  end

  defmacro __using__(opts \\ []) do
    aggregate_module = Keyword.get(opts, :aggregate)
    strategy_opts = Keyword.take(opts, Strategy.strategy_keys())

    quote location: :keep do
      @behaviour Dobro.App.CommandHandler
      @aggregate_module unquote(aggregate_module)
      @handler_strategy_opts unquote(Macro.escape(strategy_opts))

      def __handler_strategy_opts__, do: @handler_strategy_opts

      import Dobro.Pipeline, except: [finalize: 1, finalize: 2]
      alias Dobro.Pipeline
      import Dobro.App.CommandHandler, only: [handle: 2, handle: 3, handle: 4]
      import Dobro.App.CommandHandler.Helpers
    end
  end

  @doc """
  Defines a command handler for a given command module.

  ## Examples

  ```elixir
  handle CommandModule, :do_something, contract: DoSomethingDomainContract
  ```
  """
  defmacro handle(command_module, call_fn, opts \\ [])

  defmacro handle(command_module, call_fn, opts) when is_atom(call_fn) and is_list(opts) do
    if Keyword.get(opts, :execution_strategy) == :actor do
      assert_command_identity!(command_module)
    end

    quote do
      def execute(%unquote(command_module){} = command, execution_context) do
        pipeline(command, execution_context, unquote(opts))
        |> default_execute(unquote(call_fn), @aggregate_module, __MODULE__)
      end

      def execute(%unquote(command_module){} = command) do
        pipeline(command, unquote(opts))
        |> default_execute(unquote(call_fn), @aggregate_module, __MODULE__)
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

  defp assert_command_identity!(command_module) do
    unless Code.ensure_loaded?(command_module) and
             function_exported?(command_module, :__identity__, 0) do
      raise CompileError,
            description:
              "command #{inspect(command_module)} requires identity for execution_strategy: :actor"
    end
  end
end
