defmodule Dobro.Domain.Aggregate do
  @moduledoc """
  Macro for building event-driven aggregate roots.

  Aggregates encapsulate consistency boundaries. All mutations record domain events
  via `add_event/3`, apply them with `apply_changes/1`, and validate invariants
  before returning `{:ok, %{value: aggregate, events: events}}`.

  See the [package README](readme.html) for a complete guide with examples.
  """
  alias Dobro.Domain.Invariants
  alias Dobro.Pipeline
  alias Dobro.Schema

  defmodule AggregateState do
    @moduledoc """
    State for the aggregate pipeline
    - aggregate: the aggregate instance
    - events: the domain events to be applied to the aggregate
    """
    defstruct value: %{}, events: []
  end

  defmacro __using__(opts \\ []) do
    persistence_strategy = Keyword.get(opts, :persistence_strategy)

    quote location: :keep do
      use Invariants
      use Schema
      import Dobro.State
      import Dobro.Pipeline
      import Dobro.Domain.Aggregate.EventMacros
      import Dobro.Domain.Aggregate.StateMacros
      use Dobro.Contract

      @before_compile Dobro.Domain.Aggregate
      @persistence_strategy unquote(persistence_strategy)

      def __stream_name__, do: "#{__MODULE__}_events"
      def __persistence_strategy__, do: @persistence_strategy
    end
  end

  defmodule StateMacros do
    @moduledoc """
    Macros for defining state
    """
    defmacro state(do: block) do
      quote do
        schema do
          field :version, :integer, required: true
          unquote(block)
        end
      end
    end
  end

  defmodule EventMacros do
    @moduledoc """
    Macros for defining event application
    """

    defmacro defapply(event_module) do
      quote do
        @doc """
        Applies the event to the aggregate
        """
        def apply(%__MODULE__{} = aggregate, %unquote(event_module){} = event) do
          apply_event(aggregate, event)
        end
      end
    end

    defmacro defapply(event_module, fields) when is_list(fields) do
      quote do
        @doc """
        Applies the event to the aggregate
        """
        def apply(%__MODULE__{} = aggregate, %unquote(event_module){} = event) do
          apply_event(aggregate, event, unquote(fields))
        end
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote location: :keep do
      alias Dobro.Domain.Aggregate.Helpers

      def pipeline(%{} = input), do: Helpers.pipeline(__MODULE__, input)

      def pipeline(%__MODULE__{} = value, %{} = input),
        do: Helpers.pipeline(__MODULE__, value, input)

      @doc """
      Builds an event for the aggregate.

      Pass an event module to map the contract input conventionally, optionally with a
      post-transform `(aggregate, attrs) -> attrs` to merge extra payload fields.
      """
      def add_event(pipeline, event_module_or_function, opts \\ [])

      def add_event(%Pipeline{} = pipeline, event_module, transform_fn, opts)
          when is_atom(event_module) and is_function(transform_fn, 2) and is_list(opts) do
        Helpers.add_event(pipeline, __MODULE__, event_module, transform_fn, opts)
      end

      def add_event(%Pipeline{} = pipeline, event_module, transform_fn)
          when is_atom(event_module) and is_function(transform_fn, 2) do
        Helpers.add_event(pipeline, __MODULE__, event_module, transform_fn)
      end

      def add_event(%Pipeline{} = pipeline, event_module_or_function, opts) when is_list(opts) do
        Helpers.add_event(pipeline, __MODULE__, event_module_or_function, opts)
      end

      defdelegate with_deleted_at(aggregate, attrs), to: Helpers

      def verify(%Pipeline{} = pipeline), do: Helpers.verify(__MODULE__, pipeline)

      def apply(aggregate, event), do: Helpers.unhandled_apply(__MODULE__, aggregate, event)

      def apply_event(%__MODULE__{} = aggregate, %{} = event),
        do: Helpers.apply_event(__MODULE__, aggregate, event)

      def apply_event(%__MODULE__{} = aggregate, %{} = event, fields) when is_list(fields),
        do: Helpers.apply_event(__MODULE__, aggregate, event, fields)

      def apply_changes(%Pipeline{} = pipeline), do: Helpers.apply_changes(__MODULE__, pipeline)
    end
  end
end
