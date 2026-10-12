defmodule Dobro.Schema do
  @moduledoc """
  Macros for schemas.

  ## Named schemas

  Use `defschema/1-3` for a nested field-bag module (no `new`/`cast`):

      defschema Fields do
        field :name, :string, required: true
        field :count, :integer, default: 0
      end

  ## Inline schemas

  Use `schema/1-2` when the fields belong to the current module (aggregates,
  standalone schema modules):

      use Dobro.Schema

      schema do
        field :name, :string, required: true
      end

  ## Extends

  Share field definitions with `extends:`:

      defschema Fields do
        field :name, :string, required: true
        field :count, :integer, default: 0
      end

      defschema Create, extends: Fields

      defschema Update, extends: Fields do
        field :note, :string
        field :count, :integer, required: true
      end

  Inherited fields are copied into the child schema. Child `field/3` declarations
  override parent fields with the same name.

  Define the parent before any child that extends it. `defcontract` is built on
  `defschema` and adds `new`/`cast`.

  ## Inline nested schemas

  For one-off nested shapes (Ecto-style embeds), pass a `do` block to `field/3`:

      defcontract SendNotificationParams do
        field :schedule, Schedule do
          field :offset_value, :integer, required: true
          field :offset_unit, :string
        end
      end

  This defines `SendNotificationParams.Schedule` (a nested `defschema` or
  `defcontract` matching the parent) and registers `field :schedule, Schedule`.
  Prefer a top-level `defschema`/`defcontract` when the shape is reused.

  Inside a `schema` block you can also call `extend/2` directly when you need
  inherited fields inserted mid-block (e.g. after an aggregate `:version` field).
  """

  @pending_fields_attr :__dobro_schema_fields__

  defmacro __using__(opts) do
    defaults = Keyword.get(opts, :defaults, [])
    mod = __CALLER__.module

    quote do
      @dobro_schema_use_defaults unquote(defaults)
      import Dobro.Schema, only: [schema: 1, schema: 2, defschema: 1, defschema: 2, defschema: 3]
      Dobro.Schema.ensure_pending_fields_attr!(unquote(mod))
    end
  end

  defmacro defschema(module_name, opts, do: block) when is_list(opts) do
    build_defschema(module_name, block, __CALLER__, opts)
  end

  defmacro defschema(module_name, do: block) do
    build_defschema(module_name, block, __CALLER__, [])
  end

  defmacro defschema(module_name, opts) when is_list(opts) do
    build_defschema(module_name, nil, __CALLER__, opts)
  end

  defmacro defschema(module_name) do
    build_defschema(module_name, nil, __CALLER__, [])
  end

  defmacro schema(opts \\ [], do: block) do
    {extends, opts} = Keyword.pop(opts, :extends)
    schema_defaults = Keyword.get(opts, :defaults, [])
    except = field_names_in(block)

    body =
      case extends do
        nil ->
          block

        parent ->
          parent_mod = resolve_schema_module(parent, __CALLER__)

          quote do
            extend(unquote(parent_mod), except: unquote(except))
            unquote(block)
          end
      end

    quote do
      use_defaults = Module.get_attribute(__MODULE__, :dobro_schema_use_defaults, [])
      defaults = Keyword.merge(use_defaults, unquote(schema_defaults))

      Module.register_attribute(__MODULE__, :schema, accumulate: true)
      Module.register_attribute(__MODULE__, :fields, accumulate: true)
      Module.put_attribute(__MODULE__, :defaults, defaults)

      import Dobro.Schema
      import Dobro.Schema.TypeHelpers

      unquote(body)

      defstruct @fields

      @before_compile {unquote(__MODULE__), :__before_compile__}
    end
  end

  @doc """
  Injects fields from a parent schema into the current schema block.

  Prefers a compiled parent `__schema__/0`. While the host module is still
  expanding, falls back to field ASTs registered via `register_pending_fields!/3`
  (used by `defschema` so aggregate `state extends:` can see sibling schemas).
  """
  defmacro extend(parent, opts \\ []) do
    except = Keyword.get(opts, :except, [])
    parent_mod = resolve_schema_module(parent, __CALLER__)

    field_asts =
      parent_mod
      |> field_asts_for(__CALLER__)
      |> Enum.reject(fn
        {:field, _, [name | _]} when is_atom(name) -> name in except
        _ -> false
      end)

    {:__block__, [], field_asts}
  end

  defmacro field(name, type, opts \\ []) do
    {block, opts} = Keyword.pop(opts, :do)

    if block do
      inline_nested_field(name, type, opts, block, __CALLER__)
    else
      # Read @defaults when this body runs (after schema/1 sets it), not at macro
      # expansion time — expansion of nested field calls can precede evaluation of
      # the Module.put_attribute call that stores use/schema defaults.
      quote bind_quoted: [name: name, type: type, opts: opts] do
        defaults = Module.get_attribute(__MODULE__, :defaults, [])
        opts = Keyword.merge(defaults, opts)
        Dobro.Schema.__field__(name, type, opts, __ENV__)
      end
    end
  end

  defp inline_nested_field(name, type, opts, block, env) do
    kind = Module.get_attribute(env.module, :dobro_schema_kind) || :schema

    define =
      case kind do
        :contract ->
          quote do
            require Dobro.Contract
            Dobro.Contract.defcontract(unquote(type), do: unquote(block))
          end

        _schema ->
          quote do
            defschema(unquote(type), do: unquote(block))
          end
      end

    quote do
      unquote(define)
      field(unquote(name), unquote(type), unquote(opts))
    end
  end

  def __field__(name, type, opts, %Macro.Env{module: module}) do
    Module.put_attribute(module, :schema, {name, {type, opts}})
    Module.put_attribute(module, :fields, name)
  end

  @doc false
  def resolve_schema_module(extends_ast, env) do
    do_resolve_schema_module(extends_ast, env)
  end

  @doc false
  def ensure_pending_fields_attr!(host_mod) when is_atom(host_mod) do
    Module.register_attribute(host_mod, @pending_fields_attr, accumulate: false)

    if Module.get_attribute(host_mod, @pending_fields_attr) == nil do
      Module.put_attribute(host_mod, @pending_fields_attr, %{})
    end

    :ok
  end

  @doc false
  def register_pending_fields!(host_mod, schema_mod, field_asts)
      when is_atom(host_mod) and is_atom(schema_mod) and is_list(field_asts) do
    ensure_pending_fields_attr!(host_mod)
    map = Module.get_attribute(host_mod, @pending_fields_attr) || %{}
    Module.put_attribute(host_mod, @pending_fields_attr, Map.put(map, schema_mod, field_asts))
    :ok
  end

  @doc false
  def field_asts_for(parent, env) do
    env.module
    |> module_and_ancestors()
    |> Enum.find_value(&pending_fields(&1, parent))
    |> case do
      nil -> fields_from_compiled_parent!(parent)
      fields -> fields
    end
  end

  defp build_defschema(module_name, block, env, opts) do
    {kind, opts} = Keyword.pop(opts, :kind, :schema)
    {schema_block, module_block} = split_schema_block(block)
    full_name = resolve_schema_module(module_name, env)
    schema_opts = rewrite_extends_opt(opts, env)

    register_pending_fields!(
      env.module,
      full_name,
      pending_field_asts(schema_block, schema_opts, env)
    )

    quote do
      defmodule unquote(module_name) do
        use Dobro.Schema

        # Must be a macro: `@attr` is not visible to later macros in this body.
        Dobro.Schema.__set_schema_kind__(unquote(kind))

        schema(unquote(schema_opts), do: unquote(schema_block))
        unquote(module_block)
      end
    end
  end

  @doc false
  defmacro __set_schema_kind__(kind) do
    Module.put_attribute(__CALLER__.module, :dobro_schema_kind, kind)
    quote do: :ok
  end

  defp rewrite_extends_opt(opts, env) do
    opts = Keyword.drop(opts, [:kind])

    case Keyword.pop(opts, :extends) do
      {nil, rest} ->
        rest

      {extends_ast, rest} ->
        Keyword.put(rest, :extends, resolve_schema_module(extends_ast, env))
    end
  end

  defp pending_field_asts(schema_block, schema_opts, env) do
    child = block_expressions(schema_block)
    except = field_names_in(schema_block)

    inherited =
      case Keyword.get(schema_opts, :extends) do
        nil ->
          []

        parent when is_atom(parent) ->
          parent
          |> field_asts_for(env)
          |> Enum.reject(fn
            {:field, _, [name | _]} when is_atom(name) -> name in except
            _ -> false
          end)
      end

    inherited ++ child
  end

  defp module_and_ancestors(nil), do: []

  defp module_and_ancestors(mod) do
    parts = Module.split(mod)

    for n <- length(parts)..1//-1 do
      parts |> Enum.take(n) |> Module.concat()
    end
  end

  defp pending_fields(nil, _parent), do: nil

  defp pending_fields(host_mod, parent) do
    case Module.get_attribute(host_mod, @pending_fields_attr) do
      %{^parent => fields} when is_list(fields) -> fields
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp fields_from_compiled_parent!(parent) do
    _ = Code.ensure_loaded(parent)

    unless function_exported?(parent, :__schema__, 0) do
      raise ArgumentError,
            "schema extends: #{inspect(parent)} is not a compiled schema module. " <>
              "Define the parent schema before schemas that extend it."
    end

    parent.__schema__()
    |> Enum.reverse()
    |> Enum.map(fn {name, {type, opts}} ->
      quote do
        field(unquote(name), unquote(Macro.escape(type)), unquote(Macro.escape(opts)))
      end
    end)
  end

  # Already-resolved module atoms (from `defschema` / `state`) pass through.
  # Single-segment aliases nest under the caller; multi-segment aliases are absolute.
  defp do_resolve_schema_module(atom, _env) when is_atom(atom) and not is_nil(atom) do
    if atom |> Atom.to_string() |> String.starts_with?("Elixir.") do
      atom
    else
      raise ArgumentError,
            "schema extends: expected a module, got: #{inspect(atom)}"
    end
  end

  defp do_resolve_schema_module({:__aliases__, _, [one]}, env) when is_atom(one) do
    Module.concat(env.module, one)
  end

  defp do_resolve_schema_module({:__aliases__, _, parts}, _env) when is_list(parts) do
    Module.concat(parts)
  end

  defp do_resolve_schema_module(other, _env) do
    raise ArgumentError,
          "schema extends: expected a module, got: #{Macro.to_string(other)}"
  end

  defp field_names_in(schema_block) do
    schema_block
    |> block_expressions()
    |> Enum.flat_map(fn
      {:field, _, [name | _]} when is_atom(name) -> [name]
      _ -> []
    end)
  end

  defp split_schema_block(block) do
    {schema_exprs, module_exprs} =
      block
      |> block_expressions()
      |> Enum.split_with(&match?({:field, _, _}, &1))

    {{:__block__, [], schema_exprs}, {:__block__, [], module_exprs}}
  end

  # Flatten nested blocks so callers can `unquote` a field `__block__` into
  # `defschema`/`defcontract` without losing fields to the non-field split.
  defp block_expressions({:__block__, _, expressions}) do
    Enum.flat_map(expressions, &block_expressions/1)
  end

  defp block_expressions(nil), do: []
  defp block_expressions(expression), do: [expression]

  defmodule TypeHelpers do
    @moduledoc """
    Additional helper macros for describing schemata:
      - list_of
      - one_of
      - one_of_input
      - non_null
    """
    alias Dobro.Schema.{ListOf, NonNull, OneOf, OneOfInput}

    defmacro list_of(type_ast) do
      quote do
        ListOf.new(unquote(type_ast))
      end
    end

    @doc """
    Declares that a value is exactly one of `type_asts`, discriminated by `discr_fn`.

    Prefer this, `defoneof/3`, or `use Dobro.Schema.OneOf` over transport-specific
    encodings.
    """
    defmacro one_of(type_asts, discr_fn) do
      quote do
        OneOf.new(
          unquote(type_asts),
          unquote(discr_fn)
        )
      end
    end

    @doc """
    Declares an exclusive keyed variant map (exactly one named variant).

    Prefer `one_of/2` or `defoneof/3` on contracts — transports such as GraphQL
    synthesize keyed `@oneOf` inputs from those. Use this only when keyed
    exclusivity is intentional at the schema layer.
    """
    defmacro one_of_input(variants) do
      quote do
        OneOfInput.new(unquote(variants))
      end
    end

    defmacro non_null(type_ast) do
      quote do
        NonNull.new(unquote(type_ast))
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @type t :: %__MODULE__{}

      def __schema__, do: @schema
      def __schema__(key) when is_atom(key), do: Keyword.get(__schema__(), key)
      def __schema__!(key) when is_atom(key), do: Keyword.fetch!(__schema__(), key)
      def __fields__, do: @fields

      def type_for(field) do
        case Keyword.get(@schema, field, nil) do
          nil ->
            {:error,
             Dobro.Error.new(:field_not_found,
               description: "#{field} is not found on #{__MODULE__}"
             )}

          {type, _opts} ->
            {:ok, type}
        end
      end
    end
  end

  defmodule ListOf do
    @moduledoc """
    Describes a type that is a list of +of_type+
    """
    defstruct [:of_type]

    def new(of_type) do
      struct(__MODULE__, %{of_type: of_type})
    end
  end

  defmodule NonNull do
    @moduledoc """
    Describes a type whose value must be present (not nil or empty string).
    """
    defstruct [:of_type]

    def new(of_type) do
      struct(__MODULE__, %{of_type: of_type})
    end
  end
end
