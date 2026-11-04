defmodule Dobro.Infra.Data.Query.Enrich do
  @moduledoc false

  alias Dobro.App.Selection
  alias Dobro.Infra.Data.Query.Helpers

  @type loader ::
          {module(), atom()}
          | {:query, repo :: module(), query_module :: module()}

  @type enrich_spec :: %{
          required(:path) => [atom()],
          required(:key) => atom(),
          required(:into) => atom(),
          required(:with) => loader()
        }

  @doc """
  Batch-enriches query results by foreign key.

  Collects `key` values under each enrich `path` (map or list of maps), calls each
  distinct loader once, then puts results under `into`.

  Loaders:

  - `{module, fun}` — `fun(ids, context)` returns `%{id => value}`
  - `{:query, repo, query_module}` — runs `repo.run(query_module, %{ids: ids, query: ...}, context)`
    and indexes `%{items: items}` (or `:entries`) by `:id`
  """
  @spec run(term(), [enrich_spec()], term()) :: term()
  def run(result, [], _context), do: result

  def run(%{items: items} = page, enriches, context) when is_list(items) do
    %{page | items: apply_many(items, enriches, context)}
  end

  def run(%{entries: entries} = page, enriches, context) when is_list(entries) do
    %{page | entries: apply_many(entries, enriches, context)}
  end

  def run(row, enriches, context) when is_map(row) do
    case apply_many([row], enriches, context) do
      [enriched] -> enriched
      _ -> row
    end
  end

  def run(other, _enriches, _context), do: other

  defp apply_many(rows, enriches, context) do
    selection = Helpers.selection(context)

    enriches
    |> Enum.filter(&selected?(&1, selection))
    |> Enum.group_by(& &1.with)
    |> Enum.reduce(rows, fn {loader, group}, acc_rows ->
      ids =
        acc_rows
        |> Enum.flat_map(fn row -> Enum.flat_map(group, &collect_ids(row, &1)) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      options = call_loader(loader, ids, context)
      Enum.map(acc_rows, fn row -> Enum.reduce(group, row, &stitch(&2, &1, options)) end)
    end)
  end

  defp selected?(_enrich, nil), do: true

  defp selected?(%{path: path, into: into}, %Selection{} = selection) do
    case walk_selection(selection, path) do
      :field_selected ->
        true

      %Selection{} = nested ->
        Map.has_key?(nested.associations, into) or MapSet.member?(nested.fields, into)

      nil ->
        false
    end
  end

  # Walk association path. A final segment present only in `fields` (e.g. list_of)
  # returns `:field_selected` — nested `into` selection is not available.
  defp walk_selection(selection, []), do: selection

  defp walk_selection(%Selection{associations: associations, fields: fields}, [name]) do
    cond do
      Map.has_key?(associations, name) -> Map.fetch!(associations, name)
      MapSet.member?(fields, name) -> :field_selected
      true -> nil
    end
  end

  defp walk_selection(%Selection{associations: associations}, [name | rest]) do
    case Map.get(associations, name) do
      nil -> nil
      nested -> walk_selection(nested, rest)
    end
  end

  defp collect_ids(row, %{path: path, key: key}) do
    row
    |> get_path(path)
    |> nodes()
    |> Enum.map(&get(&1, key))
  end

  defp stitch(row, %{path: path, key: key, into: into}, options) do
    update_path(row, path, fn value ->
      value
      |> nodes()
      |> Enum.map(&attach_into(&1, key, into, options))
      |> rewrap(value)
    end)
  end

  defp attach_into(nil, _key, _into, _options), do: nil

  defp attach_into(map, key, into, options) when is_map(map) do
    map = atomize_string_keys(map)
    id = Map.get(map, key)
    Map.put(map, into, Map.get(options, id))
  end

  defp attach_into(other, _key, _into, _options), do: other

  defp nodes(nil), do: []
  defp nodes(list) when is_list(list), do: list
  defp nodes(map) when is_map(map), do: [map]
  defp nodes(_), do: []

  defp rewrap(nodes, original) when is_list(original), do: nodes
  defp rewrap([], _original), do: nil
  defp rewrap([node], _original), do: node
  defp rewrap(nodes, _original), do: nodes

  defp get_path(row, []), do: row

  defp get_path(row, [name | rest]) when is_map(row) do
    case get(row, name) do
      nil -> nil
      value -> get_path(value, rest)
    end
  end

  defp get_path(_row, _path), do: nil

  defp update_path(row, [], fun), do: fun.(row)

  defp update_path(row, [name | rest], fun) when is_map(row) do
    case get(row, name) do
      nil ->
        row

      value ->
        Map.put(prefer_atom_key(row, name), name, update_path(value, rest, fun))
    end
  end

  defp update_path(row, _path, _fun), do: row

  defp prefer_atom_key(map, key) when is_atom(key) do
    str = Atom.to_string(key)

    if Map.has_key?(map, key) do
      map
    else
      case Map.pop(map, str) do
        {nil, _} -> map
        {value, rest} -> Map.put(rest, key, value)
      end
    end
  end

  defp get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp atomize_string_keys(map) do
    if Enum.any?(Map.keys(map), &is_binary/1) do
      Map.new(map, fn
        {k, v} when is_binary(k) ->
          try do
            {String.to_existing_atom(k), v}
          rescue
            ArgumentError -> {k, v}
          end

        {k, v} ->
          {k, v}
      end)
    else
      map
    end
  end

  defp call_loader(_loader, [], _context), do: %{}

  defp call_loader({mod, fun}, ids, context) when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [ids, context])
  end

  defp call_loader({:query, repo, query_module}, ids, context) do
    page_size = max(length(ids), 1)

    args = %{
      ids: ids,
      query: %{page: 1, page_size: page_size}
    }

    case repo.run(query_module, args, context) do
      {:ok, %{items: items}} when is_list(items) -> index_by_id(items)
      {:ok, %{entries: entries}} when is_list(entries) -> index_by_id(entries)
      _ -> %{}
    end
  end

  defp index_by_id(items) do
    Map.new(items, fn item ->
      id = Map.get(item, :id) || Map.get(item, "id")
      {id, item}
    end)
  end
end
