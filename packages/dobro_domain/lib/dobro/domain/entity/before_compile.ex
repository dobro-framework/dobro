defmodule Dobro.Domain.Entity.BeforeCompile do
  @moduledoc """
  Generates compile-time callbacks for entities.
  """

  @doc "Returns the quoted AST injected by `Dobro.Domain.Entity` before compile."
  def quote(module) do
    quote do
      unquote(callbacks_quote())
      unquote(impls_quote(module))
    end
  end

  defp callbacks_quote do
    quote do
      alias Dobro.Domain.Entity.Helpers

      def cast(%Dobro.Pipeline{} = pipeline), do: Helpers.cast(__MODULE__, pipeline)

      @impl true
      def load(nil), do: {:ok, nil}

      @impl true
      def load(value), do: Helpers.load(__MODULE__, value)

      def load!(value), do: Helpers.load!(__MODULE__, value)

      @impl true
      def equal?(%__MODULE__{} = a, %__MODULE__{} = b), do: Helpers.equal?(a, b)

      def equal?(_, _), do: false

      @impl true
      def identity(%__MODULE__{} = entity), do: Helpers.identity(entity)
    end
  end

  defp impls_quote(_module) do
    # Avoid String.Chars during tests (protocol consolidation). Identity is
    # available via identity/1.
    quote do
    end
  end
end
