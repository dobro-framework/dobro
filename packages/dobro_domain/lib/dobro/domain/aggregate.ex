defmodule Dobro.Domain.Aggregate do
  @moduledoc """
  Macro for building event-driven aggregate roots.

  Aggregates encapsulate consistency boundaries. All mutations record domain events
  via `add_event/3`, apply them with `apply_changes/1`, and validate invariants
  before returning `{:ok, %{value: aggregate, events: events}}`.

  ## Options

    * `:persistence_strategy` — optional per-aggregate override (`:stateful` /
      `:event_sourced`).

  ## Identity

  Declare identity fields with `identity do` (same shape as command identity).
  Omitted → default `field :id, :id`. Identity fields are injected into `state`
  as `immutable: true` and must not be redeclared there.

      use Dobro.Domain.Aggregate

      identity do
        field :case_id, :id
      end

      state do
        field :tenant_id, :id, required: true
      end

  See `__identity_fields__/0`.

  See the [package README](readme.html) for a complete guide with examples.
  """
  alias Dobro.Domain.Invariants
  alias Dobro.Pipeline
  alias Dobro.Schema

  defmodule AggregateState do
    @moduledoc """
    State for the aggregate pipeline
    - value: the aggregate instance
    - events: the domain events to be applied to the aggregate
    - workspace: intermediate results for later pipeline steps (same idea as
      command/query handler workspace)
    """
    defstruct value: %{}, events: [], workspace: %{}
  end

  defmacro __using__(opts \\ []) do
    persistence_strategy = Keyword.get(opts, :persistence_strategy)

    if Keyword.has_key?(opts, :identity) do
      raise ArgumentError, """
      Dobro.Domain.Aggregate no longer accepts identity: on use/1.

      Declare identity with an identity do block instead:

          use Dobro.Domain.Aggregate

          identity do
            field :id, :id
          end

      Or omit identity do to default to field :id, :id.
      """
    end

    # Defaults until `identity do` runs (must appear before `state`).
    Module.put_attribute(__CALLER__.module, :dobro_identity_fields, [{:id, :id}])
    Module.put_attribute(__CALLER__.module, :dobro_identity_declared, false)

    quote location: :keep do
      use Invariants
      use Schema
      import Dobro.State
      import Dobro.Pipeline
      import Dobro.Domain.Aggregate
      import Dobro.Domain.Aggregate.EventMacros
      import Dobro.Domain.Aggregate.StateMacros
      use Dobro.Contract

      @before_compile Dobro.Domain.Aggregate
      @persistence_strategy unquote(persistence_strategy)

      def __stream_name__, do: "#{__MODULE__}_events"
      def __persistence_strategy__, do: @persistence_strategy
    end
  end

  @doc """
  Declares the aggregate's identity fields (sole declaration — not on `state`).

  Must appear before `state`. Default when omitted is `field :id, :id`.
  """
  defmacro identity(do: block) do
    fields = parse_identity_fields(block, __CALLER__)

    if fields == [] do
      raise ArgumentError, "identity do must declare at least one field"
    end

    Module.put_attribute(__CALLER__.module, :dobro_identity_fields, fields)
    Module.put_attribute(__CALLER__.module, :dobro_identity_declared, true)

    quote do
      # Identity recorded on module attributes for `state` injection / before_compile.
      :ok
    end
  end

  defp parse_identity_fields(block, env) do
    block
    |> block_expressions()
    |> Enum.flat_map(fn
      {:field, _meta, [name, type | _rest]} when is_atom(name) ->
        type = Macro.expand(type, env)
        [{name, type}]

      {:field, meta, _args} ->
        raise ArgumentError,
              "identity field requires name and type, got: #{Macro.to_string({:field, meta, []})}"

      other ->
        raise ArgumentError,
              "identity do only accepts field/2 lines, got: #{Macro.to_string(other)}"
    end)
  end

  defp block_expressions({:__block__, _, expressions}), do: expressions
  defp block_expressions(nil), do: []
  defp block_expressions(expression), do: [expression]

  defmodule StateMacros do
    @moduledoc """
    Macros for defining state.

    Accepts `extends:` (same semantics as `Dobro.Schema.schema/2`). Extended
    fields are inserted after `:version` (and identity fields) and before the
    `state` block so those framework fields stay first.

    Identity fields (from `identity do`, default `:id`) are injected as
    `immutable: true`. Redeclaring them in `state` or an extended schema is an error.

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
      identity_fields = Module.get_attribute(env.module, :dobro_identity_fields) || [{:id, :id}]
      identity_names = Enum.map(identity_fields, &elem(&1, 0))

      field_names =
        block
        |> block_expressions()
        |> Enum.flat_map(fn
          {:field, _, [name | _]} when is_atom(name) -> [name]
          _ -> []
        end)

      redeclared = Enum.filter(identity_names, &(&1 in field_names))

      if redeclared != [] do
        raise CompileError,
          description:
            "identity field(s) #{inspect(redeclared)} must not be declared in state — " <>
              "declare them only in identity do",
          file: env.file,
          line: env.line
      end

      # Exclude identity from extends so a parent Fields schema cannot contribute them.
      except = Enum.uniq(identity_names ++ field_names)

      identity_ast =
        for {name, type} <- identity_fields do
          quote do
            field unquote(name), unquote(type), immutable: true
          end
        end

      body =
        case extends do
          nil ->
            quote do
              field :version, :integer, required: true
              unquote_splicing(identity_ast)
              unquote(block)
            end

          ast ->
            parent = Dobro.Schema.resolve_schema_module(ast, env)

            quote do
              field :version, :integer, required: true
              unquote_splicing(identity_ast)
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

  defmacro __before_compile__(env) do
    identity_fields = Module.get_attribute(env.module, :dobro_identity_fields) || [{:id, :id}]
    identity_names = Enum.map(identity_fields, &elem(&1, 0))

    quote location: :keep do
      alias Dobro.Domain.Aggregate.Helpers

      @doc "Identity field names for this aggregate (always a list)."
      def __identity_fields__, do: unquote(identity_names)

      def pipeline(%{} = input), do: Helpers.pipeline(__MODULE__, input)

      def pipeline(%__MODULE__{} = value, %{} = input),
        do: Helpers.pipeline(__MODULE__, value, input)

      @doc """
      Builds an event for the aggregate.

      Pass an event module to map the contract input conventionally, optionally with a
      post-transform `(aggregate, attrs) -> attrs` to merge extra payload fields.

      Alternatively pass a builder function:

        * `(aggregate, input) -> {:ok, event}` — conventional 2-arity builder
        * `(pipeline) -> {:ok, event}` — pipeline-aware builder (can read workspace)
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
      defdelegate put_in_workspace(pipeline, key, value), to: Helpers
      defdelegate get_from_workspace(pipeline, key), to: Helpers

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
