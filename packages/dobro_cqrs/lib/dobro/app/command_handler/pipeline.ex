defmodule Dobro.App.CommandHandler.Pipeline do
  @moduledoc """
  Command-handler pipeline steps: identity resolution, specification checks,
  domain invocation, and persistence used during command execution.
  """

  alias Dobro.App.Command.Strategy
  alias Dobro.App.CommandHandler.State
  alias Dobro.App.ExecutionContext
  alias Dobro.App.ResultCaster
  alias Dobro.App.Scope
  alias Dobro.Domain.SpecificationContext
  alias Dobro.Error
  alias Dobro.Pipeline
  alias Dobro.Tenant

  import Dobro.Pipeline, except: [finalize: 1, finalize: 2]

  @doc "Initialises a command-handler pipeline from a command struct."
  def pipeline(%_{} = command) do
    pipeline(command, [])
  end

  @doc "Initialises a command-handler pipeline from a command and context or options."
  def pipeline(%_{} = command, context_or_opts) do
    case context_or_opts do
      %ExecutionContext{} = execution_context ->
        pipeline(command, execution_context, [])

      opts when is_list(opts) ->
        state = %State{}

        Pipeline.new(
          state: state,
          input: command,
          config: %{tenant: nil, schema_module: command, opts: opts}
        )
        |> setup_context()
        |> transform_payload(Keyword.get(opts, :transform_payload))
        |> build_contract(Keyword.get(opts, :contract))
    end
  end

  def pipeline(%_{} = command, %ExecutionContext{} = execution_context, opts)
      when is_list(opts) do
    state = %State{}

    Pipeline.new(
      state: state,
      input: command,
      config: %{execution_context: execution_context, tenant: nil, opts: opts}
    )
    |> setup_context()
    |> transform_payload(Keyword.get(opts, :transform_payload))
    |> build_contract(Keyword.get(opts, :contract))
  end

  def run(pipeline, function) do
    bind(pipeline, fn pipeline ->
      function.(pipeline.state.contract)
      |> case do
        {:ok, result} -> put_result(pipeline, result)
        {:error, error} -> add_error(pipeline, error)
      end
    end)
  end

  def setup_context(pipeline) do
    execution_context =
      Map.get(pipeline.config, :execution_context, %ExecutionContext{})

    scope_context = Scope.setup!(pipeline.input.scope, execution_context)

    case Tenant.normalize(scope_context.tenant) do
      {:ok, tenant} ->
        scope_context = %{scope_context | tenant: tenant}

        pipeline
        |> put_in([Access.key(:config), Access.key(:scope_context)], scope_context)
        |> put_in([Access.key(:config), Access.key(:tenant)], tenant)

      {:error, %Error{} = error} ->
        merge_errors(pipeline, error)

      {:error, reason} ->
        merge_errors(pipeline, Error.new(reason))
    end
  end

  def put_result(pipeline, result) do
    put_in(pipeline.state.result, result)
  end

  def put_in_workspace(pipeline, key, value) do
    put_in(pipeline.state.workspace[key], value)
  end

  def get_from_workspace(pipeline, key) do
    pipeline.state.workspace[key]
  end

  def identify(pipeline, opts \\ [])

  def identify(%Pipeline{input: _input} = pipeline, opts) do
    identify_fn = Keyword.get(opts, :identify, :get_by)
    custom_identify_fn_provided = Keyword.has_key?(opts, :identify)
    identity = pipeline.input.identity

    identity_fn =
      if is_nil(identity) do
        nil
      else
        Keyword.get(opts, :identity_fn, &default_identity_fn(&1, identify_fn))
      end

    bind(pipeline, fn pipeline ->
      resolved_identity = if identity_fn, do: identity_fn.(identity), else: {:ok, nil}

      if is_nil(identity) and not custom_identify_fn_provided do
        pipeline
      else
        apply_resolved_identity(pipeline, resolved_identity)
      end
    end)
  end

  def put_aggregate_result(%Pipeline{state: %{unit_of_work: %{aggregate: aggregate}}} = pipeline) do
    bind(pipeline, fn pipeline ->
      put_in(pipeline.state.result, aggregate)
    end)
  end

  def specify(%Pipeline{} = pipeline, specifications) do
    bind(pipeline, fn pipeline ->
      context = specification_context(pipeline)

      case check_specifications(specifications, context) do
        :ok -> pipeline
        {:error, error} -> merge_errors(pipeline, error)
      end
    end)
  end

  def emit(%Pipeline{} = pipeline, event_function, _opts \\ []) do
    bind(pipeline, fn pipeline ->
      put_in(pipeline.state, %{
        pipeline.state
        | events: [event_function.(pipeline) | pipeline.state.events]
      })
    end)
  end

  # Transaction wrapping lives in `Dobro.App.Command.Commit` (only when the
  # event delivery strategy needs persist+stage atomicity).
  def commit_direct(%Pipeline{} = pipeline, opts \\ []) do
    do_commit_direct(pipeline, opts)
  end

  def do_commit_direct(pipeline, _opts \\ []) do
    alias Dobro.App.Command.Commit

    bind(pipeline, fn pipeline ->
      strategies = Strategy.resolve(nil, pipeline.config.opts)

      case Commit.run(
             strategies,
             pipeline.state.unit_of_work,
             pipeline.state.events,
             pipeline.config.tenant,
             pipeline.input.message_identity,
             pipeline.state.unit_of_work.aggregate
           ) do
        {:ok, unit_of_work, events} ->
          put_in(pipeline.state, %{
            pipeline.state
            | unit_of_work: unit_of_work,
              events: events
          })

        {:error, error} ->
          pipeline |> merge_errors(error)
      end
    end)
  end

  def default_execute(%Pipeline{} = pipeline, call_fn, aggregate_module, handler_module) do
    specifications = Keyword.get(pipeline.config.opts, :if, [])
    transform_result_fn = Keyword.get(pipeline.config.opts, :transform_result)

    pipeline
    |> specify(specifications)
    |> identify(pipeline.config.opts)
    |> call_and_commit(call_fn, aggregate_module, pipeline.config.opts, handler_module)
    |> put_aggregate_result()
    |> put_result_version()
    |> transform_result(transform_result_fn)
    |> finalize([:result, :version, :events])
  end

  @doc """
  Finalizes a command pipeline and casts `:result` to the command's `result` type.
  """
  def finalize(%Pipeline{input: %mod{}} = pipeline, :result) do
    case Pipeline.finalize(pipeline, :result) do
      {:ok, result} -> ResultCaster.cast_message_result(mod, result)
      other -> other
    end
  end

  def finalize(%Pipeline{input: %mod{}} = pipeline, keys) when is_list(keys) do
    case Pipeline.finalize(pipeline, keys) do
      {:ok, wrapped} -> cast_wrapped_result(wrapped, keys, mod)
      other -> other
    end
  end

  def finalize(%Pipeline{} = pipeline), do: Pipeline.finalize(pipeline)

  defp cast_wrapped_result(wrapped, keys, mod) do
    if :result in keys do
      case ResultCaster.cast_message_result(mod, wrapped.result) do
        {:ok, casted} -> {:ok, %{wrapped | result: casted}}
        error -> error
      end
    else
      {:ok, wrapped}
    end
  end

  def specification_context(%Pipeline{
        state: %{contract: contract},
        input: input,
        config: config
      }) do
    SpecificationContext.new(
      contract,
      Map.get(input, :identity),
      Map.get(config, :tenant)
    )
  end

  def put_result_version(%Pipeline{state: %{result: result}} = pipeline) do
    if is_map(result) and Map.has_key?(result, :version) do
      put_in(pipeline.state.version, Map.get(result, :version))
    else
      pipeline
    end
  end

  def call_and_commit(pipeline, call_fn, aggregate_module, opts \\ [], handler_module \\ nil) do
    bind(pipeline, fn pipeline ->
      strategies = Strategy.resolve(handler_module, opts)
      {execution_mod, execution_opts} = strategies.execution

      execution_mod.execute(
        pipeline,
        call_fn,
        aggregate_module,
        Keyword.merge(opts, execution_opts),
        strategies
      )
    end)
  end

  def call_aggregate(pipeline, aggregate_module, aggregate_fn) do
    if pipeline.state.unit_of_work.aggregate do
      apply(aggregate_module, aggregate_fn, [
        pipeline.state.unit_of_work.aggregate,
        contract_from_pipeline(pipeline)
      ])
    else
      apply(aggregate_module, aggregate_fn, [contract_from_pipeline(pipeline)])
    end
  end

  def contract_from_pipeline(pipeline) do
    pipeline.state.contract
  end

  def invoke_direct(pipeline, call_fn, aggregate_module, _opts \\ []) do
    case call_aggregate(pipeline, aggregate_module, call_fn) do
      {:ok, result} ->
        put_in(pipeline.state, %{
          pipeline.state
          | unit_of_work: %{pipeline.state.unit_of_work | aggregate: result.value},
            events: result.events ++ pipeline.state.events
        })

      {:error, error} ->
        pipeline |> merge_errors(error)
    end
  end

  def transform_payload(pipeline, transform_fn) when is_function(transform_fn) do
    bind(pipeline, fn pipeline ->
      put_in(pipeline.input.payload, transform_fn.(pipeline.input.payload))
    end)
  end

  def transform_payload(pipeline, _), do: pipeline

  def transform_result(pipeline, transform_fn) when is_function(transform_fn) do
    bind(pipeline, fn pipeline ->
      put_in(pipeline.state.result, transform_fn.(pipeline.state.result))
    end)
  end

  def transform_result(pipeline, _), do: pipeline

  def put_contract(pipeline, contract) do
    put_in(pipeline.state.contract, contract)
  end

  def build_contract(pipeline, contract_module \\ nil) do
    if contract_module do
      bind(pipeline, &put_built_contract(&1, contract_module))
    else
      put_contract(pipeline, pipeline.input.payload)
    end
  end

  defp put_built_contract(pipeline, contract_module) do
    case contract_module.new(pipeline.input.payload) do
      {:ok, built_contract} ->
        put_contract(pipeline, built_contract)

      {:error, error} ->
        merge_errors(pipeline, error)
    end
  end

  defp apply_resolved_identity(pipeline, {:ok, identity}) do
    put_in(pipeline.state.identity, identity)
  end

  defp apply_resolved_identity(pipeline, {:error, missing}) do
    merge_errors(
      pipeline,
      Error.new(:missing_identity_fields, description: inspect(missing))
    )
  end

  defp check_specifications(specifications, context) do
    Enum.reduce_while(specifications, :ok, fn specification, acc ->
      if specification.satisfied_by?(context) do
        {:cont, acc}
      else
        {:halt, {:error, specification_error(specification)}}
      end
    end)
  end

  defp specification_error(specification) do
    Error.new(specification.reason(), description: specification.description())
  end

  defp default_identity_fn(identity, identify_fn) do
    identity_map = Map.from_struct(identity)
    identity_keys = Map.keys(identity_map)

    if identify_fn == :get and identity_keys == [:id],
      do: {:ok, Map.get(identity_map, hd(identity_keys))},
      else: {:ok, identity_map}
  end
end
