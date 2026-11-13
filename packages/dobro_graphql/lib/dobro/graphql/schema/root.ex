defmodule Dobro.Graphql.Schema.Root do
  @moduledoc """
  Imports per-context notation modules into an Absinthe schema.

  Each module is imported and stamped. The stamp is a macro call, so the schema
  recompiles when that notation module recompiles. A root object is declared
  here when one of those modules extends it.
  """

  defmacro __using__(opts) do
    modules =
      opts
      |> Keyword.fetch!(:modules)
      |> Enum.map(&Macro.expand(&1, __CALLER__))

    imports =
      for module <- modules do
        quote do
          import_types(unquote(module))
          import_type_extensions(unquote(module))
          require unquote(module)
          unquote(module).schema_stamp()
        end
      end

    roots =
      for identifier <- [:query, :mutation, :subscription],
          Enum.any?(modules, &extends?(&1, identifier)) do
        root_block(identifier)
      end

    quote do
      import_types Absinthe.Type.Custom
      import_types Dobro.Graphql.Scalars
      import_types Dobro.Graphql.Payload

      unquote_splicing(roots)
      unquote_splicing(imports)
    end
  end

  defp extends?(module, identifier) do
    Code.ensure_compiled!(module)
    [definition] = module.__absinthe_blueprint__().schema_definitions

    Enum.any?(definition.type_extensions, fn extension ->
      extension.definition.identifier == identifier
    end)
  end

  defp root_block(:query) do
    quote do
      query do
      end
    end
  end

  defp root_block(:mutation) do
    quote do
      mutation do
      end
    end
  end

  defp root_block(:subscription) do
    quote do
      subscription do
      end
    end
  end
end
