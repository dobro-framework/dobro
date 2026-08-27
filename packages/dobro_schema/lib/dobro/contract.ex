defmodule Dobro.Contract do
  @moduledoc """
  Macros for defining contracts
  """

  defmacro __using__(_opts \\ []) do
    mod = __CALLER__.module

    quote do
      import Dobro.Contract

      Module.register_attribute(unquote(mod), :contracts, accumulate: true)
      @before_compile {unquote(__MODULE__), :__before_compile__}
    end
  end

  defmacro defcontract(module_name, do: block) do
    build_contract(module_name, block, __CALLER__)
  end

  defmacro defcontract(module_name) do
    build_contract(module_name, nil, __CALLER__)
  end

  defmacro __before_compile__(_env) do
    quote do
      def __contracts__, do: @contracts
    end
  end

  defp build_contract(module_name, block, %{module: mod}) do
    {schema_block, module_block} = split_contract_block(block)

    quote do
      defmodule unquote(module_name) do
        use Dobro.Schema
        import Dobro.Pipeline

        alias Dobro.Contract.Helpers

        schema(do: unquote(schema_block))
        unquote(module_block)

        @doc """
        Creates a new contract
        """
        def new(value), do: Helpers.new(__MODULE__, value)

        @doc """
        Creates a new contract and raises an error if the creation fails
        """
        def new!(value), do: Helpers.new!(__MODULE__, value)

        @doc """
        Casts the contract
        """
        def cast(%Dobro.Pipeline{} = pipeline),
          do: Helpers.cast(__MODULE__, pipeline)
      end

      Module.put_attribute(unquote(mod), :contracts, unquote(module_name))
    end
  end

  defp split_contract_block(block) do
    {schema_exprs, module_exprs} =
      block
      |> block_expressions()
      |> Enum.split_with(&match?({:field, _, _}, &1))

    {{:__block__, [], schema_exprs}, {:__block__, [], module_exprs}}
  end

  defp block_expressions({:__block__, _, expressions}), do: expressions
  defp block_expressions(nil), do: []
  defp block_expressions(expression), do: [expression]
end
