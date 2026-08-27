defmodule Dobro.Domain.Aggregate.Helpers do
  @moduledoc """
  Pipeline helpers for domain aggregates generated via `Dobro.Domain.Aggregate`.

  Handles event application, hydration, and aggregate state transitions.
  """

  alias Dobro.App.DataTransfer.DTO
  alias Dobro.Domain.Aggregate.AggregateState
  alias Dobro.Pipeline

  import Dobro.Pipeline
  import Dobro.State

  @doc "Initialises an aggregate pipeline for a new aggregate from input."
  def pipeline(aggregate_module, %{} = input) do
    config = %{schema_module: aggregate_module}
    state = %AggregateState{value: struct(aggregate_module, version: 0)}
    Pipeline.new(state: state, input: input, config: config)
  end

  @doc "Initialises an aggregate pipeline from an existing aggregate and input."
  def pipeline(aggregate_module, aggregate, %{} = input) do
    config = %{schema_module: aggregate_module}
    state = %AggregateState{value: aggregate}
    Pipeline.new(state: state, input: input, config: config)
  end

  def add_event(pipeline, aggregate_module, event_module, transform_fn, opts)
      when is_atom(event_module) and is_function(transform_fn, 2) and is_list(opts) do
    bind(pipeline, fn pipeline ->
      conditions = Keyword.get(opts, :if)

      if exec_event?(pipeline, conditions) do
        do_add_event(pipeline, aggregate_module, event_module, transform_fn)
      else
        pipeline
      end
    end)
  end

  def add_event(pipeline, aggregate_module, event_module, transform_fn)
      when is_atom(event_module) and is_function(transform_fn, 2) do
    add_event(pipeline, aggregate_module, event_module, transform_fn, [])
  end

  def add_event(pipeline, aggregate_module, event_module_or_function, opts)
      when is_list(opts) do
    bind(pipeline, fn pipeline ->
      conditions = Keyword.get(opts, :if)

      if exec_event?(pipeline, conditions) do
        do_add_event(pipeline, aggregate_module, event_module_or_function, opts)
      else
        pipeline
      end
    end)
  end

  @doc """
  Post-transform helper for delete events — adds `deleted_at` to convention-mapped attrs.
  """
  def with_deleted_at(_aggregate, attrs) do
    Map.put(attrs, :deleted_at, DateTime.utc_now(:microsecond))
  end

  def verify(aggregate_module, %Pipeline{} = pipeline) do
    pipeline
    |> validate(aggregate_module.__schema__())
    |> precondition(fn state -> aggregate_module.check_invariants(state) end)
  end

  def unhandled_apply(aggregate_module, aggregate, event) do
    IO.warn(
      "Unhandled event: #{inspect(event.__struct__)} on aggregate: #{inspect(aggregate_module)}"
    )

    {:ok, aggregate}
  end

  def apply_event(aggregate_module, aggregate, %{} = event) do
    pipeline(aggregate_module, aggregate, event.payload)
    |> hydrate_all()
    |> put_in_value(:version, event.version)
    |> finalize(:value)
  end

  def apply_event(aggregate_module, aggregate, %{} = event, fields) when is_list(fields) do
    pipeline(aggregate_module, aggregate, event.payload)
    |> hydrate(fields)
    |> put_in_value(:version, event.version)
    |> finalize(:value)
  end

  def apply_changes(aggregate_module, %Pipeline{} = pipeline) do
    pipeline
    |> bind(fn pipeline ->
      pipeline = version_events(pipeline)

      pipeline.state.events
      |> Enum.reduce(pipeline, &apply_single_event(aggregate_module, &2, &1))
    end)
    |> then(&verify(aggregate_module, &1))
    |> finalize([:value, :events])
  end

  defp do_add_event(pipeline, aggregate_module, event_module_or_function, opts)

  defp do_add_event(%Pipeline{} = pipeline, aggregate_module, event_function, _opts)
       when is_function(event_function, 2) do
    event =
      event_from_function(aggregate_module, pipeline.state.value, pipeline.input, event_function)

    put_in(pipeline.state, %{pipeline.state | events: [event | pipeline.state.events]})
  end

  defp do_add_event(%Pipeline{} = pipeline, aggregate_module, event_module, transform_fn)
       when is_atom(event_module) and is_function(transform_fn, 2) do
    do_add_event(
      pipeline,
      aggregate_module,
      fn aggregate, input ->
        event_from_input(aggregate, input, event_module, transform_fn)
      end,
      []
    )
  end

  defp do_add_event(%Pipeline{} = pipeline, aggregate_module, event_module, opts)
       when is_atom(event_module) do
    do_add_event(
      pipeline,
      aggregate_module,
      fn aggregate, input -> event_from_input(aggregate, input, event_module) end,
      opts
    )
  end

  defp event_from_function(_aggregate_module, aggregate, %{} = input, event_function) do
    case event_function.(aggregate, input) do
      {:ok, event} -> event
      {:error, error} -> raise "Failed to build event: #{inspect(error)}"
    end
  end

  defp event_from_input(aggregate, input, event_module, transform_fn \\ nil) do
    attrs =
      input
      |> DTO.to_dto()
      |> maybe_put_aggregate_id(aggregate)
      |> maybe_transform_payload(aggregate, transform_fn)

    event_module.new(%{payload: attrs})
  end

  defp maybe_transform_payload(attrs, aggregate, transform_fn) when is_function(transform_fn, 2) do
    transform_fn.(aggregate, attrs)
  end

  defp maybe_transform_payload(attrs, _aggregate, _), do: attrs

  defp maybe_put_aggregate_id(attrs, %{id: id}) when not is_nil(id), do: Map.put(attrs, :id, id)
  defp maybe_put_aggregate_id(attrs, _), do: attrs

  defp version_events(%Pipeline{} = pipeline) do
    base_version = pipeline.state.value.version

    versioned_events =
      pipeline.state.events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} -> version_event(event, base_version + index + 1) end)

    put_in(pipeline.state, %{pipeline.state | events: versioned_events})
  end

  defp version_event(%{} = event, version) do
    %{event | version: version}
  end

  defp exec_event?(pipeline, conditions) when is_list(conditions) do
    conditions |> Enum.all?(&exec_event?(pipeline, &1))
  end

  defp exec_event?(pipeline, {:changed, field}) do
    Map.has_key?(pipeline.state.value, field) and
      Map.get(pipeline.state.value, field) != Map.get(pipeline.input, field)
  end

  defp exec_event?(_pipeline, _), do: true

  defp apply_single_event(aggregate_module, pipeline, event) do
    case aggregate_module.apply(pipeline.state.value, event) do
      {:ok, aggregate} -> put_in(pipeline.state.value, aggregate)
      {:error, error} -> add_error(pipeline, error)
    end
  end
end
