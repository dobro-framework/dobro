defmodule Dobro.Infra.Data.Query.One do
  @moduledoc false

  import Ecto.Query

  alias Dobro.Infra.Data.Query.{Helpers, Spec, StrategyOpts}

  def run(repo_module, %Spec{} = spec, args, context) do
    selection = Helpers.selection(context)
    id = Map.fetch!(args, spec.id_field)
    strategy_opts = StrategyOpts.build(repo_module, context, spec)

    queryable =
      spec
      |> build_queryable(repo_module, args, context)
      |> apply_id_filter(spec, id)
      |> prepare_query(spec, selection)

    case repo_module.one(queryable, strategy_opts) do
      {:ok, result} when not is_nil(selection) ->
        {:ok, postload_associations(result, spec.schema, spec.preloads, selection)}

      other ->
        other
    end
  end

  defp prepare_query(queryable, spec, nil) do
    Helpers.apply_preloads(queryable, spec.preloads, nil)
  end

  defp prepare_query(queryable, spec, selection) do
    if Helpers.selection_covered_by_spec?(selection, spec) do
      maybe_apply_projection(queryable, spec, selection)
    else
      # Selection includes non-repo fields (e.g. GraphQL `:content`) — load the full row.
      Helpers.apply_preloads(queryable, spec.preloads, nil)
    end
  end

  defp build_queryable(%Spec{query: {mod, fun, 2}}, _repo_module, args, context),
    do: apply(mod, fun, [args, context])

  defp build_queryable(%Spec{schema: schema, root_binding: binding}, _repo_module, _args, _context)
       when not is_nil(binding) do
    from(s in schema, as: ^binding)
  end

  defp build_queryable(%Spec{schema: schema}, _repo_module, _args, _context), do: schema

  defp apply_id_filter(queryable, spec, id) when is_atom(queryable) do
    from(row in queryable, where: field(row, ^spec.id_field) == ^id)
  end

  defp apply_id_filter(%Ecto.Query{} = queryable, spec, id) do
    id_field = spec.id_field

    case spec.root_binding do
      binding when is_atom(binding) ->
        from [{^binding, row}] in queryable, where: field(row, ^id_field) == ^id

      _ ->
        from row in queryable, where: field(row, ^id_field) == ^id
    end
  end

  defp maybe_apply_projection(queryable, %{fields: fields}, _selection) when map_size(fields) == 0,
    do: queryable

  defp maybe_apply_projection(queryable, spec, selection) do
    preloads = selected_preloads(spec.preloads, selection)

    needed =
      spec
      |> Helpers.needed_fields(selection, nil)
      |> Kernel.++(foreign_keys_for_preloads(spec.schema, preloads))
      |> Enum.uniq()

    queryable
    |> Helpers.apply_joins(spec, needed)
    |> Helpers.apply_select(spec.fields, needed)
  end

  defp postload_associations(result, schema, preloads, selection) do
    Enum.reduce(preloads, result, fn preload_spec, acc ->
      if Helpers.preload_selected?(preload_spec.name, selection) do
        load_assoc_into_map(acc, schema, preload_spec, selection)
      else
        acc
      end
    end)
  end

  defp load_assoc_into_map(result, root_schema, %{name: name} = preload_spec, selection) do
    case root_schema.__schema__(:association, name) do
      %Ecto.Association.BelongsTo{owner_key: owner_key, related_key: related_key} ->
        case Map.get(result, owner_key) do
          nil ->
            Map.put(result, name, nil)

          fk ->
            assoc =
              preload_spec
              |> Helpers.assoc_preload_query(selection)
              |> where([row], field(row, ^related_key) == ^fk)
              |> Dobro.Infra.Repo.one()

            Map.put(result, name, assoc)
        end

      _ ->
        result
    end
  end

  defp selected_preloads(preloads, selection) do
    Enum.filter(preloads, &Helpers.preload_selected?(&1.name, selection))
  end

  defp foreign_keys_for_preloads(_schema, []), do: []

  defp foreign_keys_for_preloads(schema, preloads) do
    Enum.flat_map(preloads, fn %{name: name} ->
      case schema.__schema__(:association, name) do
        %Ecto.Association.BelongsTo{owner_key: key} -> [key]
        _ -> []
      end
    end)
  end
end
