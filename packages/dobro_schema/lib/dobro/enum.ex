defmodule Dobro.Enum do
  @moduledoc """
  Transport-agnostic enumerations for Dobro contracts.

  Enums are plain Elixir modules that know their allowed values and how to
  cast wire values (strings from JSON/REST/CLI, atoms from Absinthe) into
  those values. GraphQL, REST, and other adapters map them independently —
  e.g. Absinthe emits an `enum` type; a REST client would send/receive
  strings.

      defenum SortDirection do
        value :asc, description: "Ascending"
        value :desc, description: "Descending"
      end

  Use the module as a field type in a contract:

      field :direction, SortDirection, required: true
  """

  defmacro __using__(_opts \\ []) do
    quote do
      import Dobro.Enum, only: [defenum: 2]
    end
  end

  @doc "Returns true when `module` was defined with `defenum`."
  @spec enum?(term()) :: boolean()
  def enum?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__enum__?, 0) and
      module.__enum__?()
  end

  def enum?(_), do: false

  @doc """
  Defines an enumeration module.

  Each `value/1` or `value/2` call registers a member. The resulting module
  exposes `values/0`, `cast/1`, `new/1`, and `load/1`.
  """
  defmacro defenum(module_name, do: block) do
    quote do
      defmodule unquote(module_name) do
        @moduledoc false

        Module.register_attribute(__MODULE__, :enum_values, accumulate: true)
        Module.register_attribute(__MODULE__, :enum_description, accumulate: false)

        import Dobro.Enum, only: [value: 1, value: 2, description: 1]

        unquote(block)

        @before_compile Dobro.Enum
      end
    end
  end

  @doc "Sets the enumeration description (used by GraphQL and docs)."
  defmacro description(text) when is_binary(text) do
    quote do
      Module.put_attribute(__MODULE__, :enum_description, unquote(text))
    end
  end

  @doc "Registers an enumeration member."
  defmacro value(name, opts \\ [])

  defmacro value(name, opts) do
    quote bind_quoted: [name: name, opts: opts] do
      unless is_atom(name) do
        raise ArgumentError, "enum value name must be an atom, got: #{inspect(name)}"
      end

      Module.put_attribute(__MODULE__, :enum_values, {name, opts})
    end
  end

  defmacro __before_compile__(env) do
    values =
      env.module
      |> Module.get_attribute(:enum_values)
      |> List.wrap()
      |> Enum.reverse()

    if values == [] do
      raise CompileError,
        description: "#{inspect(env.module)} defined with defenum/2 but has no value/1 calls",
        file: env.file,
        line: env.line
    end

    value_names = Enum.map(values, fn {name, _opts} -> name end)
    value_opts = Map.new(values)
    description = Module.get_attribute(env.module, :enum_description)

    quote do
      @values unquote(value_names)
      @value_opts unquote(Macro.escape(value_opts))
      @enum_description unquote(description)

      @doc false
      def __enum__?, do: true

      @doc false
      def singular?, do: true

      @doc "Returns the allowed enumeration atoms."
      @spec values() :: [atom()]
      def values, do: @values

      @doc "Returns per-value options (e.g. descriptions)."
      @spec value_opts() :: %{optional(atom()) => keyword()}
      def value_opts, do: @value_opts

      @doc "Returns the enumeration description, if any."
      @spec description() :: String.t() | nil
      def description, do: @enum_description

      @doc "Returns true when `value` is a member of this enumeration."
      @spec member?(term()) :: boolean()
      def member?(value), do: value in @values

      @doc "Casts a wire value into an enumeration atom."
      @spec cast(term()) :: {:ok, atom()} | {:error, [Dobro.Error.t()]}
      def cast(value), do: Dobro.Enum.cast_value(__MODULE__, value, @values)

      @doc "Alias for `cast/1` used by contract field assignment."
      @spec new(term()) :: {:ok, atom()} | {:error, [Dobro.Error.t()]}
      def new(value), do: cast(value)

      @doc "Alias for `cast/1` used when hydrating persisted values."
      @spec load(term()) :: {:ok, atom()} | {:error, [Dobro.Error.t()]}
      def load(value), do: cast(value)
    end
  end

  @doc false
  @spec cast_value(module(), term(), [atom()]) :: {:ok, atom()} | {:error, [Dobro.Error.t()]}
  def cast_value(module, value, values) when is_atom(value) do
    cond do
      value in values ->
        {:ok, value}

      true ->
        # Accept uppercase atoms Absinthe/JSON may produce (e.g. :ASC).
        downcased = value |> Atom.to_string() |> String.downcase() |> String.to_existing_atom()

        if downcased in values do
          {:ok, downcased}
        else
          invalid(module, value)
        end
    end
  rescue
    ArgumentError -> invalid(module, value)
  end

  def cast_value(module, value, values) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    case Enum.find(values, &(Atom.to_string(&1) == normalized)) do
      nil -> invalid(module, value)
      atom -> {:ok, atom}
    end
  end

  def cast_value(module, value, _values), do: invalid(module, value)

  defp invalid(module, value) do
    {:error,
     [
       Dobro.Error.new(:invalid_enum,
         description: "#{inspect(value)} is not a valid #{inspect(module)} value"
       )
     ]}
  end
end
