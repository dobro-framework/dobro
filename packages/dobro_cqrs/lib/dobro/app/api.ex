defmodule Dobro.App.Api do
  @moduledoc """
  Public API DSL with policy + middleware pipeline.
  """

  alias Dobro.App.Api.Pipeline
  alias Dobro.App.{ExecutionContext, ResultCaster}

  defmacro __using__(opts \\ []) do
    context = Keyword.get(opts, :context)
    port = Keyword.fetch!(opts, :port)
    surfaces = Keyword.get(opts, :surfaces, [])
    api_port = Dobro.App.Api.Port

    quote do
      use Dobro.Spec.Adapter,
        ports: [unquote(port), unquote(api_port)],
        port_for: [{unquote(api_port), [surfaces: unquote(surfaces)]}]

      use Dobro.Contract

      import Dobro.App.Api
      import Dobro.App.Api.WaitForHelpers
      import Dobro.Schema.TypeHelpers

      Module.register_attribute(__MODULE__, :commands, accumulate: true)
      Module.register_attribute(__MODULE__, :queries, accumulate: true)
      Module.put_attribute(__MODULE__, :context, unquote(context))

      @before_compile {unquote(__MODULE__), :__before_compile__}
    end
  end

  def __command__(name, command_module, opts, %Macro.Env{module: module}) do
    Module.put_attribute(module, :commands, {name, {command_module, opts}})
  end

  def __query__(name, query_module, opts, %Macro.Env{module: module}) do
    Module.put_attribute(module, :queries, {name, {query_module, opts}})
  end

  def __context__(context, %Macro.Env{module: module}) do
    Module.put_attribute(module, :context, context)
  end

  defmacro context(context) do
    __context__(context, __CALLER__)
  end

  def handle_result(module, type, result, context, returning, args \\ %{})

  def handle_result(module, :command, result, context, returning, args)
      when not is_nil(returning) do
    # Merge original mutation args (e.g. tenant_id) with the command result so
    # tenant-scoped `returning:` queries still receive required identity fields.
    returning_input =
      args
      |> result_to_map()
      |> Map.merge(result_to_map(extract_result(result)))

    case apply(module, returning, [returning_input, context]) do
      {:ok, returning_result} -> {:ok, %{result | result: returning_result}}
      {:error, error} -> {:error, error}
    end
  end

  def handle_result(_module, :command, result, _context, _returning, _args) do
    {:ok, result}
  end

  def handle_result(_, :query, result, _, _, _) do
    {:ok, result}
  end

  def cast_route_result(:query, result, _returning, result_mod) do
    ResultCaster.cast(result, result_mod)
  end

  def cast_route_result(:command, result, returning, _result_mod) when not is_nil(returning) do
    {:ok, result}
  end

  def cast_route_result(:command, %{result: _} = result, _returning, result_mod) do
    case ResultCaster.cast(result.result, result_mod) do
      {:ok, casted} -> {:ok, %{result | result: casted}}
      {:error, error} -> {:error, error}
    end
  end

  def cast_route_result(:command, result, _returning, _result_mod) do
    {:ok, result}
  end

  defp extract_result(%{result: result}) do
    result
  end

  defp result_to_map(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
  end

  defp result_to_map(%{} = map), do: map
  defp result_to_map(_other), do: %{}

  defmacro route(name, opts \\ []) do
    env = __CALLER__

    policy = Keyword.get(opts, :policy)
    handler_mod = Keyword.fetch!(opts, :to)
    command_mod = Keyword.get(opts, :command)
    returning = Keyword.get(opts, :returning)
    wait_for = Keyword.get(opts, :wait_for)
    query_mod = Keyword.get(opts, :query)
    middleware = Keyword.get(opts, :middleware, [])
    description = Keyword.get(opts, :description)
    explicit_result = expand_result(Keyword.get(opts, :result), __CALLER__)

    {type, query_or_cmd_mod} =
      case {command_mod, query_mod} do
        {nil, nil} -> raise "Must provide either a query or a command"
        {nil, query} -> {:query, query}
        {command, nil} -> {:command, command}
      end

    expanded_message = Macro.expand(query_or_cmd_mod, env)
    result_mod = explicit_result || message_result(expanded_message)

    route_opts =
      [returning: returning, result: result_mod, description: description]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    run =
      quote do
        args = var!(args)
        context = var!(context)

        with {:ok, query_or_cmd} <- unquote(query_or_cmd_mod).new(args),
             :ok <- maybe_subscribe_to_stream(unquote(wait_for)),
             {:ok, query_or_cmd_result} <- query_or_cmd |> unquote(handler_mod).execute(context),
             :ok <- maybe_wait_for(unquote(wait_for), query_or_cmd, query_or_cmd_result),
             {:ok, result} <-
               handle_result(
                 __MODULE__,
                 unquote(type),
                 query_or_cmd_result,
                 context,
                 unquote(returning),
                 args
               ),
             {:ok, casted} <-
               cast_route_result(unquote(type), result, unquote(returning), unquote(result_mod)) do
          {:ok, casted}
        else
          {:error, pipeline} -> {:error, pipeline}
        end
      end

    quote location: :keep do
      unquote(
        case type do
          :command ->
            quote do
              unquote(__MODULE__).__command__(
                unquote(name),
                unquote(query_or_cmd_mod),
                unquote(route_opts),
                __ENV__
              )
            end

          :query ->
            quote do
              unquote(__MODULE__).__query__(
                unquote(name),
                unquote(query_or_cmd_mod),
                unquote(route_opts),
                __ENV__
              )
            end
        end
      )

      def unquote(name)(args, context) do
        context = ExecutionContext.new(context)

        var!(args) = args
        var!(context) = context

        Pipeline.execute(
          Pipeline.PipelineContext.new(%{
            name: {unquote(env.module), unquote(name)},
            type: unquote(type),
            policy: unquote(policy),
            middleware: unquote(middleware),
            args: args,
            run: fn -> unquote(run) end
          }),
          context
        )
      end
    end
  end

  defp expand_result(nil, _env), do: nil

  defp expand_result(result_mod, env) do
    Macro.expand(result_mod, env)
  end

  defp message_result(mod) do
    Code.ensure_compiled(mod)

    if function_exported?(mod, :__result__, 0) do
      mod.__result__()
    end
  end

  def route_result(api_module, :command, name) do
    {_command_mod, opts} = api_module.__commands__(name)
    Keyword.get(opts, :result)
  end

  def route_result(api_module, :query, name) do
    {_query_mod, opts} = api_module.__queries__(name)
    Keyword.get(opts, :result)
  end

  def mutation_result_module(api_module, _command_fn, opts) do
    case Keyword.get(opts, :returning) do
      nil ->
        Keyword.fetch!(opts, :result)

      returning ->
        {_query_mod, query_opts} = api_module.__queries__(returning)
        Keyword.fetch!(query_opts, :result)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __commands__, do: @commands
      def __commands__(name), do: Keyword.get(__commands__(), name)
      def __queries__, do: @queries
      def __queries__(name), do: Keyword.get(__queries__(), name)
      def __context__, do: @context
    end
  end

  defmodule WaitForHelpers do
    @moduledoc """
    Helper functions for waiting for events
    """

    @doc """
    Wait for a projection to be updated
    @param stream_name The stream name to subscribe to
    @param projection_name The projection name to wait for
    @return A wait for tuple which matches the projection name and event
    """
    defmacro wait_for_projection(projection_module) do
      quote do
        {
          :wait_for_projection,
          unquote(projection_module)
        }
      end
    end

    def maybe_subscribe_to_stream({:wait_for_projection, projection_module}) do
      stream_name = projection_module.__ack_stream_name__()

      case Phoenix.PubSub.subscribe(Dobro.Config.pubsub!(), stream_name) do
        :ok -> :ok
        _ -> {:error, :could_not_subscribe_to_stream}
      end
    end

    def maybe_subscribe_to_stream(_), do: :ok

    def maybe_wait_for(
          {:wait_for_projection, projection_module} = wait_for,
          input,
          %{events: events} = result
        )
        when is_list(events) and length(events) > 0 do
      result_version = result.version
      projection_name = projection_module.__name__()
      causation_id = input.message_identity.id

      receive do
        {:projection_updated, ^projection_name, ^causation_id, version} ->
          if version >= result_version do
            :ok
          else
            maybe_wait_for(wait_for, input, result)
          end
      after
        5000 ->
          {:error, :timeout_waiting_for_projection}
      end
    end

    def maybe_wait_for(_, _, _), do: :ok
  end
end
