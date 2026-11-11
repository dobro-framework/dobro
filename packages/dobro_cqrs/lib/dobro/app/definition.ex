defmodule Dobro.App.Definition do
  @moduledoc """
  Module for defining command/query definitions
  """

  defmacro __using__(opts \\ []) do
    mod = __CALLER__.module
    namespace = Keyword.get(opts, :namespace)

    quote do
      import Dobro.App.Definition
      use Dobro.Contract

      Module.register_attribute(unquote(mod), :namespace, accumulate: false)
      Module.put_attribute(unquote(mod), :namespace, unquote(namespace))
      Module.register_attribute(unquote(mod), :scope, accumulate: false)
      Module.register_attribute(unquote(mod), :description, accumulate: false)

      @before_compile {unquote(__MODULE__), :__before_compile__}
    end
  end

  defmacro __before_compile__(env) do
    result_fn =
      unless Module.defines?(env.module, {:__result__, 0}) do
        quote do
          def __result__, do: nil
        end
      end

    quote do
      def __namespace__, do: @namespace
      def __description__, do: @description
      unquote(result_fn)
    end
  end

  defmacro __add_scope_fn__(env) do
    scope = Module.get_attribute(env.module, :scope)

    quote do
      def __scope__, do: unquote(scope)
    end
  end

  def scope_value(:global, nil), do: {:global, nil}
  def scope_value(:dynamic, nil), do: {:dynamic, nil}
  def scope_value(:tenant, :payload), do: {:tenant, :payload}
  def scope_value(:tenant, :context), do: {:tenant, :context}

  def scope_value(scope_name, from),
    do: raise("Invalid scope: #{inspect(scope_name)} with from: #{inspect(from)}")

  defmacro scope(_scope_name, _opts \\ []) do
    quote do
      :ok
    end
  end

  defmacro result(do: block) do
    mod = __CALLER__.module
    namespace = Module.get_attribute(mod, :namespace)

    quote do
      defmodule Result do
        @moduledoc "Typed result struct returned by this command or query."
        use Dobro.Schema
        use Dobro.App.Definition, namespace: unquote(namespace)

        alias Dobro.Contract.Helpers

        schema(do: unquote(block))

        def new(value), do: Helpers.new(__MODULE__, value)
      end

      def __result__, do: Result
    end
  end

  defmacro result(contract) do
    contract = Macro.expand(contract, __CALLER__)

    quote do
      def __result__, do: unquote(contract)
    end
  end
end
