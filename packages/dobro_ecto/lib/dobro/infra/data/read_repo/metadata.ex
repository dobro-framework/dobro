defmodule Dobro.Infra.Data.ReadRepo.Metadata do
  @moduledoc """
  Declares scope and context metadata on read repos that do not use `ReadRepo`.
  """

  defmacro __using__(opts \\ []) do
    caller = __CALLER__.module
    allowed_scopes = Keyword.get(opts, :scopes, [:global, :tenant])
    context_mode = Keyword.get(opts, :context_mode, :none)

    schema_quote =
      case Keyword.get(opts, :schema) do
        nil ->
          []

        schema ->
          schema_module = Macro.expand(schema, __CALLER__)

          Module.register_attribute(caller, :read_repo_schema, persist: true)
          Module.put_attribute(caller, :read_repo_schema, schema_module)

          quote do
            @read_repo_schema unquote(schema_module)
          end
      end

    quote do
      unquote(schema_quote)

      @allowed_scopes unquote(allowed_scopes)
      @context_mode unquote(context_mode)

      def __allowed_scopes__, do: @allowed_scopes
      def context_mode, do: @context_mode
      def strategy, do: Dobro.Infra.Data.ReadRepo.NoTenantStrategy
    end
  end
end
