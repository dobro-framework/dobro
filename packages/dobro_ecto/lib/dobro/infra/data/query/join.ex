defmodule Dobro.Infra.Data.Query.Join do
  @moduledoc false

  @doc """
  Resolves a `join` DSL entry from Ecto associations at compile time.
  """
  def compile!(source_schema, join_name, root_binding, opts, compiled_joins) do
    through = Keyword.get(opts, :through)
    type = Keyword.get(opts, :type, :inner)

    {parent_schema, source_binding} =
      case through do
        nil ->
          {source_schema, root_binding}

        through_name ->
          case Enum.find(compiled_joins, &(&1.name == through_name)) do
            nil ->
              raise ArgumentError,
                    "join #{inspect(join_name)} through #{inspect(through_name)}, " <>
                      "but #{inspect(through_name)} is not defined above it"

            %{schema: schema} ->
              {schema, through_name}
          end
      end

    assoc = association!(parent_schema, join_name)

    %{
      name: join_name,
      assoc: join_name,
      schema: assoc.related,
      source: source_binding,
      type: type,
      on: on_from_association(assoc, source_binding, join_name)
    }
  end

  defp association!(schema, name) do
    unless Code.ensure_loaded?(schema) do
      raise ArgumentError, "schema #{inspect(schema)} is not loaded"
    end

    case schema.__schema__(:association, name) do
      %Ecto.Association.BelongsTo{} = assoc ->
        assoc

      %Ecto.Association.Has{} = assoc ->
        assoc

      nil ->
        raise ArgumentError,
              "association #{inspect(name)} is not defined on #{inspect(schema)}"

      other ->
        raise ArgumentError,
              "unsupported association #{inspect(other.__struct__)} for join #{inspect(name)}"
    end
  end

  defp on_from_association(%{owner_key: owner_key, related_key: related_key}, source, join_name) do
    {source, owner_key, join_name, related_key}
  end
end
