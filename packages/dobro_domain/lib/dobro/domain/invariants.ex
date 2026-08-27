defmodule Dobro.Domain.Invariants do
  @moduledoc """
  Macro for describing and checking invariants
  """

  @doc """
  Define an invariant
  - name: the name of the invariant function
  """
  defmacro invariant(name) when is_atom(name) do
    quote bind_quoted: [name: name] do
      existing = Module.get_attribute(__MODULE__, :invariants)

      unless name in existing do
        Module.put_attribute(__MODULE__, :invariants, name)
      end
    end
  end

  @doc """
  Define an invariant function
  Creates a function that must return :ok or {:error, description} and adds the function name to the aggregate's invariants
  which are validated when changes are applied to the aggregate.

  Example:

  definvariant must_be_older_than_18(%{age: age}) do
    if age < 18 do
      {:error, :must_be_older_than_18}
    else
      :ok
    end
  end
  """
  defmacro definvariant(ast, do: block) do
    {head, name} =
      case ast do
        {:when, _, [{name, _, _} = _head, _guard]} ->
          {ast, name}

        {name, _, _} = head ->
          {head, name}

        _ ->
          raise ArgumentError, """
          definvariant expects a function head, e.g.

              definvariant valid?(state) do
                :ok
              end
          """
      end

    quote do
      def unquote(head) do
        unquote(block)
      end

      invariant(unquote(name))
    end
  end

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :invariants, accumulate: true)

      import Dobro.Domain.Invariants

      @before_compile Dobro.Domain.Invariants
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      alias Dobro.Domain.Invariants.Helpers

      def __invariants__, do: @invariants

      def check_invariants(state),
        do: Helpers.check_invariants(__MODULE__, state)
    end
  end
end
