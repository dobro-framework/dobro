defmodule Dobro.Schema do
  @moduledoc """
  Macro for schemas
  """

  defmacro __using__(opts) do
    defaults = Keyword.get(opts, :defaults, [])

    quote do
      @dobro_schema_use_defaults unquote(defaults)
      import Dobro.Schema, only: [schema: 1, schema: 2]
    end
  end

  defmacro schema(opts \\ [], do: block) do
    schema_defaults = Keyword.get(opts, :defaults, [])

    quote do
      use_defaults = Module.get_attribute(__MODULE__, :dobro_schema_use_defaults, [])
      defaults = Keyword.merge(use_defaults, unquote(schema_defaults))

      Module.register_attribute(__MODULE__, :schema, accumulate: true)
      Module.register_attribute(__MODULE__, :fields, accumulate: true)
      Module.put_attribute(__MODULE__, :defaults, defaults)

      import Dobro.Schema
      import Dobro.Schema.TypeHelpers

      unquote(block)

      defstruct @fields

      @before_compile {unquote(__MODULE__), :__before_compile__}
    end
  end

  defmacro field(name, type, opts \\ []) do
    # Read @defaults when this body runs (after schema/1 sets it), not at macro
    # expansion time — expansion of nested field calls can precede evaluation of
    # the Module.put_attribute call that stores use/schema defaults.
    quote bind_quoted: [name: name, type: type, opts: opts] do
      defaults = Module.get_attribute(__MODULE__, :defaults, [])
      opts = Keyword.merge(defaults, opts)
      Dobro.Schema.__field__(name, type, opts, __ENV__)
    end
  end

  def __field__(name, type, opts, %Macro.Env{module: module}) do
    Module.put_attribute(module, :schema, {name, {type, opts}})
    Module.put_attribute(module, :fields, name)
  end

  defmodule TypeHelpers do
    @moduledoc """
    Additional helper macros for describing schemata:
      - list_of
      - one_of
      - non_null
    """
    alias Dobro.Schema.{ListOf, NonNull, OneOf}

    defmacro list_of(type_ast) do
      quote do
        ListOf.new(unquote(type_ast))
      end
    end

    defmacro one_of(type_asts, discr_fn) do
      quote do
        OneOf.new(
          unquote(type_asts),
          unquote(discr_fn)
        )
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

  defmodule OneOf do
    @moduledoc """
    Describes a union of possible +of_types+
    discr_fn is a function that will be used to determine
    which type should be used for assignment
    """
    defstruct [:of_types, :discr_fn]

    def new(of_types, discr_fn)
        when is_list(of_types) and is_function(discr_fn) do
      struct(__MODULE__, %{of_types: of_types, discr_fn: discr_fn})
    end
  end
end
