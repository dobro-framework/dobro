defmodule Dobro.Infra.Data.Query.Join do
  @moduledoc false

  @doc """
  Resolves a `join` DSL entry at compile time.

  Association joins (default):

      join :tenant, type: :left do ...

  Explicit joins (no Ecto association required):

      join :covered_person,
        schema: PersonShadowSchema,
        type: :left,
        prefix: :tenant,
        and_not_deleted: true,
        on: {
          dynamic([case: c], fragment("(?->>'covered_person_id')::bigint", c.coverage)),
          :id
        } do ...

  `on:` left side may be a column atom or a compiled `{:expr, mfa}` / DSL `dynamic(...)`.
  `and_not_deleted: true` (or a field atom) ANDs a soft-delete guard onto the ON clause.
  """
  def compile!(source_schema, join_name, root_binding, opts, compiled_joins) do
    through = Keyword.get(opts, :through)
    type = Keyword.get(opts, :type, :inner)
    prefix = Keyword.get(opts, :prefix)

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

    case Keyword.fetch(opts, :schema) do
      {:ok, schema} ->
        explicit_join!(join_name, schema, source_binding, type, prefix, opts)

      :error ->
        association_join!(parent_schema, join_name, source_binding, type, prefix)
    end
  end

  defp explicit_join!(join_name, schema, source_binding, type, prefix, opts) do
    on =
      case Keyword.fetch(opts, :on) do
        {:ok, {left_field, right_field}}
        when is_atom(left_field) and is_atom(right_field) ->
          {source_binding, left_field, join_name, right_field}

        {:ok, {{:expr, _} = left_expr, right_field}} when is_atom(right_field) ->
          {source_binding, left_expr, join_name, right_field}

        {:ok, other} ->
          raise ArgumentError,
                "join #{inspect(join_name)} explicit on: expects {left_field | expr, right_field}, got: #{inspect(other)}"

        :error ->
          raise ArgumentError,
                "join #{inspect(join_name)} with schema: requires on: {left_field, right_field}"
      end

    %{
      name: join_name,
      assoc: nil,
      schema: schema,
      source: source_binding,
      type: type,
      on: on,
      prefix: prefix,
      and_not_deleted: normalize_and_not_deleted(Keyword.get(opts, :and_not_deleted))
    }
  end

  defp association_join!(parent_schema, join_name, source_binding, type, prefix) do
    assoc = association!(parent_schema, join_name)

    %{
      name: join_name,
      assoc: join_name,
      schema: assoc.related,
      source: source_binding,
      type: type,
      on: on_from_association(assoc, source_binding, join_name),
      prefix: prefix,
      and_not_deleted: nil
    }
  end

  defp normalize_and_not_deleted(nil), do: nil
  defp normalize_and_not_deleted(true), do: :deleted
  defp normalize_and_not_deleted(field) when is_atom(field), do: field

  defp normalize_and_not_deleted(other) do
    raise ArgumentError,
          "and_not_deleted expects true or a boolean field atom, got: #{inspect(other)}"
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
