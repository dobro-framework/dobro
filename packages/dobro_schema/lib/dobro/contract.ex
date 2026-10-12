defmodule Dobro.Contract do
  @moduledoc """
  Macros for defining contracts.

  Contracts are schemas (`defschema`) plus `new`/`cast` helpers.

  ## Extends

  Share field definitions with `extends:` (same as `defschema` / `schema`):

      defschema ActionFields do
        field :name, :string, required: true
        field :target, :string, required: true
      end

      defcontract Create, extends: ActionFields

      defcontract Update, extends: ActionFields do
        field :note, :string
      end

  Inherited fields are copied into the child schema. Child `field/3` declarations
  override parent fields with the same name.

  Define the parent before any child that extends it (same module is fine).
  Prefer `defschema` for field bags that are only reused via `extends:`.
  One-off nested shapes can use `field :name, Type do ... end` (see `Dobro.Schema`).
  """

  defmacro __using__(_opts \\ []) do
    mod = __CALLER__.module

    quote do
      import Dobro.Contract
      # Include schema/1-2 so a later import does not replace `use Dobro.Schema`.
      import Dobro.Schema, only: [defschema: 1, defschema: 2, defschema: 3, schema: 1, schema: 2]
      import Dobro.Schema.OneOf, only: [defoneof: 3]
      import Dobro.Schema.OneOfBy, only: [defoneof_by: 3]

      Module.register_attribute(unquote(mod), :contracts, accumulate: true)
      Dobro.Schema.ensure_pending_fields_attr!(unquote(mod))
      @before_compile {unquote(__MODULE__), :__before_compile__}
    end
  end

  defmacro defcontract(module_name, opts, do: block) when is_list(opts) do
    build_contract(module_name, block, opts)
  end

  defmacro defcontract(module_name, do: block) do
    build_contract(module_name, block, [])
  end

  defmacro defcontract(module_name, opts) when is_list(opts) do
    build_contract(module_name, nil, opts)
  end

  defmacro defcontract(module_name) do
    build_contract(module_name, nil, [])
  end

  defmacro __before_compile__(_env) do
    quote do
      def __contracts__, do: @contracts
    end
  end

  defp build_contract(module_name, block, opts) do
    {schema_block, module_block} = split_contract_block(block)
    schema_opts = Keyword.put(opts, :kind, :contract)

    quote do
      defschema unquote(module_name), unquote(schema_opts) do
        unquote(schema_block)

        import Dobro.Pipeline

        alias Dobro.Contract.Helpers

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

      Module.put_attribute(__MODULE__, :contracts, unquote(module_name))
    end
  end

  defp split_contract_block(block) do
    {schema_exprs, module_exprs} =
      block
      |> block_expressions()
      |> Enum.split_with(&match?({:field, _, _}, &1))

    {{:__block__, [], schema_exprs}, {:__block__, [], module_exprs}}
  end

  defp block_expressions({:__block__, _, expressions}) do
    Enum.flat_map(expressions, &block_expressions/1)
  end

  defp block_expressions(nil), do: []
  defp block_expressions(expression), do: [expression]
end
