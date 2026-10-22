defmodule Dobro.Domain.Aggregate do
  @moduledoc """
  Macro for building event-driven aggregate roots.

  Aggregates encapsulate consistency boundaries. All mutations record domain events
  via `add_event/3`, apply them with `apply_changes/1`, and validate invariants
  before returning `{:ok, %{value: aggregate, events: events}}`.

  ## Options

    * `:identity` — atom naming the identity field (default `:id`). Injected into
      `state` as `immutable: true` unless already declared. See `__identity_field__/0`.
    * `:persistence_strategy` — optional per-aggregate override (`:stateful` /
      `:event_sourced`).

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
    identity_field = Keyword.get(opts, :identity, :id)

    unless is_atom(identity_field) and not is_nil(identity_field) do
      raise ArgumentError,
            "Dobro.Domain.Aggregate identity: must be an atom, got: #{inspect(identity_field)}"
    end

    # Set during expansion so `state` can read it later in the module body.
    Module.put_attribute(__CALLER__.module, :dobro_identity_field, identity_field)

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
      def __identity_field__, do: unquote(identity_field)
    end
  end

  defmodule StateMacros do
    @moduledoc """
    Macros for defining state.

    Accepts `extends:` (same semantics as `Dobro.Schema.schema/2`). Extended
    fields are inserted after `:version` (and the identity field) and before the
    `state` block so those framework fields stay first.

    The identity field (from `use Dobro.Domain.Aggregate, identity: ...`, default
    `:id`) is injected as `immutable: true` unless the `state` block already
    declares it.

    When only extending a parent schema (no extra fields), omit the `do` block:

        state extends: Fields
    """
    defmacro state(opts, do: block) when is_list(opts) do
      build_state(opts, block, __CALLER__)
    end

    defmacro state(do: block) do
      build_state([], block, __CALLER__)
    end

    defmacro state(opts) when is_list(opts) do
      build_state(opts, nil, __CALLER__)
    end

    defp build_state(opts, block, env) do
      {extends, schema_opts} = Keyword.pop(opts, :extends)
      identity_field = Module.get_attribute(env.module, :dobro_identity_field) || :id

      field_names =
        block
        |> block_expressions()
        |> Enum.flat_map(fn
          {:field, _, [name | _]} when is_atom(name) -> [name]
          _ -> []
        end)

      inject_identity? = identity_field not in field_names
      # When injecting, exclude the identity field from extends so the parent
      # does not also contribute a duplicate field.
      except =
        if inject_identity?,
          do: Enum.uniq([identity_field | field_names]),
          else: field_names

      identity_ast =
        if inject_identity? do
          quote do
            field unquote(identity_field), :id, immutable: true
          end
        else
          nil
        end

      body =
        case extends do
          nil ->
            quote do
              field :version, :integer, required: true
              unquote(identity_ast)
              unquote(block)
            end

          ast ->
            parent = Dobro.Schema.resolve_schema_module(ast, env)

            quote do
              field :version, :integer, required: true
              unquote(identity_ast)
              extend(unquote(parent), except: unquote(except))
              unquote(block)
            end
        end

      quote do
        schema unquote(schema_opts) do
          unquote(body)
        end
      end
    end

    defp block_expressions({:__block__, _, expressions}), do: expressions
    defp block_expressions(nil), do: []
    defp block_expressions(expression), do: [expression]
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
