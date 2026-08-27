defmodule Dobro.Domain.ValueObject.BeforeCompile do
  @moduledoc """
  Generates compile-time callbacks and protocol implementations for value objects.
  """

  @doc "Returns the quoted AST injected by `Dobro.Domain.ValueObject` before compile."
  def quote(module) do
    quote do
      unquote(callbacks_quote())
      unquote(impls_quote(module))
    end
  end

  defp callbacks_quote do
    quote do
      alias Dobro.Domain.ValueObject.Helpers

      def cast(%Dobro.Pipeline{} = pipeline), do: Helpers.cast(__MODULE__, pipeline)

      @impl true
      def load(nil), do: {:ok, nil}

      @impl true
      def load(value), do: Helpers.load(__MODULE__, value)

      def load!(value), do: Helpers.load!(__MODULE__, value)

      @impl true
      def equal?(%__MODULE__{} = a, %__MODULE__{} = b), do: Helpers.equal?(a, b)
    end
  end

  defp impls_quote(module) do
    quote do
      defimpl Dobro.Domain.ValueObject.ValueObjectValue, for: unquote(module) do
        def value(vo), do: unquote(module).value(vo)
      end

      defimpl String.Chars, for: unquote(module) do
        def to_string(vo),
          do: Dobro.Domain.ValueObject.Helpers.stringify(unquote(module).value(vo))
      end
    end
  end
end
