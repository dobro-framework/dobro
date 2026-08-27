defmodule Dobro.Domain.ValueObject do
  @moduledoc """
  Behaviour and macros for domain value objects.

  Use `Dobro.Domain.ValueObject.Singular` for single-field wrappers (email, URL)
  and `Dobro.Domain.ValueObject` with a `schema do` block for composite types.

  - `new/1` — validate at system boundaries
  - `load/1` — hydrate from persistence without validation
  - `value/1` — extract plain data for serialisation

  See the [package README](readme.html) for examples.
  """

  alias Dobro.Domain.Invariants
  alias Dobro.Domain.ValueObject.{BeforeCompile, Helpers}
  alias Dobro.Schema

  @type t :: any()
  @callback new(any()) :: {:ok, t()} | {:error, term()}
  @callback value(t()) :: any()
  @callback load(any()) :: t()
  @callback equal?(t(), t()) :: boolean()

  defmodule State do
    @moduledoc """
    Internal pipeline state holding the in-progress value object fields.
    """

    defstruct value: %{}
  end

  defprotocol ValueObjectValue do
    @spec value(term()) :: term()
    def value(vo)
  end

  def value(vo) when is_struct(vo), do: ValueObjectValue.value(vo)
  def value(nil), do: nil

  defmacro __using__(_opts) do
    quote do
      use Invariants
      use Schema

      @behaviour Dobro.Domain.ValueObject
      @before_compile Dobro.Domain.ValueObject

      @impl true
      def new(nil), do: nil

      @impl true
      def new(%{} = input), do: Helpers.new(__MODULE__, input)

      @impl true
      def value(vo) when is_struct(vo, __MODULE__), do: Helpers.value(vo)

      @impl true
      def value(nil), do: nil

      defoverridable value: 1

      def singular?, do: false
      defoverridable singular?: 0
    end
  end

  defmacro __before_compile__(env) do
    BeforeCompile.quote(env.module)
  end

  defmodule Singular do
    @moduledoc """
    A Value Object with a single :value field
    """
    defmacro __using__(opts) do
      type = Keyword.get(opts, :type, :string)
      required = Keyword.get(opts, :required, true)
      validate = Keyword.get(opts, :validate, [])

      quote do
        use Dobro.Domain.ValueObject

        schema enforce: true do
          field :value, unquote(type),
            required: unquote(required),
            validate: unquote(validate)
        end

        def singular?, do: true

        @impl true
        def new(input) when is_binary(input), do: new(%{value: input})

        @impl true
        def value(%__MODULE__{value: value}), do: value

        @after_compile {unquote(__MODULE__), :__define_dto_impl__}
      end
    end

    def __define_dto_impl__(env, _bytecode) do
      mod = env.module

      quoted =
        quote do
          defimpl Dobro.App.DataTransfer.DTO, for: unquote(mod) do
            def to_dto(%unquote(mod){} = vo), do: unquote(mod).value(vo)
          end
        end

      Code.eval_quoted(quoted, [], __ENV__)
    end
  end
end
