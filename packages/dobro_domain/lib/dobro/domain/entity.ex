defmodule Dobro.Domain.Entity do
  @moduledoc """
  Behaviour and macros for classic DDD child entities.

  Entities are identity-bearing nested types that live inside an aggregate's
  consistency boundary. They share the Value Object rhythm (`new` / `load` /
  `value` / invariants) but compare by identity, not by full value.

  ## Identity

      use Dobro.Domain.Entity                    # identity: :id (default)
      use Dobro.Domain.Entity, identity: :line_id

  The identity field is injected as `immutable: true` unless the `schema` block
  already declares it. See `__identity_field__/0`.

  Entities have no events, version, stream, or persistence strategy — mutations
  go through the owning aggregate.

  See the [package README](readme.html) for examples.
  """

  alias Dobro.Domain.Invariants
  alias Dobro.Domain.Entity.{BeforeCompile, Helpers}

  @type t :: any()
  @callback new(any()) :: {:ok, t()} | {:error, term()}
  @callback value(t()) :: any()
  @callback load(any()) :: {:ok, t() | nil} | {:error, term()}
  @callback equal?(t(), t()) :: boolean()
  @callback identity(t()) :: term()

  defmodule State do
    @moduledoc """
    Internal pipeline state holding the in-progress entity fields.
    """

    defstruct value: %{}
  end

  defmacro __using__(opts \\ []) do
    identity_field = Keyword.get(opts, :identity, :id)

    unless is_atom(identity_field) and not is_nil(identity_field) do
      raise ArgumentError,
            "Dobro.Domain.Entity identity: must be an atom, got: #{inspect(identity_field)}"
    end

    # Set during expansion so `schema` can read it later in the module body.
    Module.put_attribute(__CALLER__.module, :dobro_identity_field, identity_field)

    quote do
      use Invariants

      @dobro_schema_use_defaults []
      Dobro.Schema.ensure_pending_fields_attr!(__MODULE__)

      import Dobro.Schema, only: [defschema: 1, defschema: 2, defschema: 3]
      import Dobro.Domain.Entity.SchemaMacros, only: [schema: 1, schema: 2]

      @behaviour Dobro.Domain.Entity
      @before_compile Dobro.Domain.Entity

      def __identity_field__, do: unquote(identity_field)

      @impl true
      def new(nil), do: nil

      @impl true
      def new(%{} = input), do: Helpers.new(__MODULE__, input)

      @impl true
      def value(entity) when is_struct(entity, __MODULE__), do: Helpers.value(entity)

      @impl true
      def value(nil), do: nil

      defoverridable value: 1
    end
  end

  defmacro __before_compile__(env) do
    BeforeCompile.quote(env.module)
  end

  defmodule SchemaMacros do
    @moduledoc false

    defmacro schema(opts \\ [], do: block) do
      identity_field = Module.get_attribute(__CALLER__.module, :dobro_identity_field) || :id

      field_names =
        block
        |> block_expressions()
        |> Enum.flat_map(fn
          {:field, _, [name | _]} when is_atom(name) -> [name]
          _ -> []
        end)

      inject_identity? = identity_field not in field_names

      {extends, schema_opts} = Keyword.pop(opts, :extends)

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
              unquote(identity_ast)
              unquote(block)
            end

          ast ->
            parent = Dobro.Schema.resolve_schema_module(ast, __CALLER__)

            quote do
              unquote(identity_ast)
              extend(unquote(parent), except: unquote(except))
              unquote(block)
            end
        end

      quote do
        require Dobro.Schema
        Dobro.Schema.schema(unquote(schema_opts), do: unquote(body))
      end
    end

    defp block_expressions({:__block__, _, expressions}), do: expressions
    defp block_expressions(nil), do: []
    defp block_expressions(expression), do: [expression]
  end
end
