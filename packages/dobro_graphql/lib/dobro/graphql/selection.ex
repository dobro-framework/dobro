defmodule Dobro.Graphql.Selection do
  @moduledoc """
  GraphQL-specific helpers for building `Dobro.App.Selection` values.
  """

  alias Absinthe.Blueprint.Document.Fragment
  alias Dobro.App.Selection
  alias Dobro.Schema.ListOf

  @typedoc "Selection struct used by read repositories."
  @type t :: Selection.t()

  defdelegate selected_fields(selection, all_fields), to: Selection

  @doc """
  Builds a selection from an Absinthe resolution and result contract module.
  """
  def from_resolution(%Absinthe.Resolution{} = resolution, result_module) do
    from_projected_fields(Absinthe.Resolution.project(resolution), resolution, result_module)
  end

  @doc false
  def from_projected_fields(projected, resolution, result_module) do
    projected = normalize_projection(projected, resolution)

    case list_item_module(result_module) do
      nil -> Selection.from_projection(projected, result_module)
      item_module -> from_list_item_projection(projected, item_module)
    end
  end

  defp from_list_item_projection(projected, item_module) do
    items = Map.get(projected, :items, %{})
    meta = Map.get(projected, :meta, %{})

    meta_fields =
      meta
      |> Map.keys()
      |> MapSet.new()

    items
    |> Selection.from_projection(item_module)
    |> Map.put(:meta_fields, meta_fields)
  end

  defp normalize_projection(projection, _resolution) when is_map(projection), do: projection

  defp normalize_projection(projection, resolution) when is_list(projection) do
    projection
    |> expand_selections(resolution)
    |> Enum.reduce(%{}, fn field, acc ->
      normalize_field(field, resolution, acc)
    end)
  end

  defp normalize_projection(_, _), do: %{}

  defp normalize_field(%{name: name, selections: selections}, resolution, acc) do
    key = normalize_key(name)
    nested = normalize_projection(selections, resolution)
    value = if nested == %{}, do: :leaf, else: nested
    Map.put(acc, key, value)
  end

  defp normalize_field({key, []}, _resolution, acc) do
    Map.put(acc, normalize_key(key), :leaf)
  end

  defp normalize_field({key, nested}, resolution, acc) when is_list(nested) do
    Map.put(acc, normalize_key(key), normalize_projection(nested, resolution))
  end

  defp normalize_field({key, _}, _resolution, acc) do
    Map.put(acc, normalize_key(key), :leaf)
  end

  # Absinthe.Resolution.project/1 expands fragments one layer deep. Nested field
  # selections still contain spreads/inlines, so expand them before normalizing.
  defp expand_selections(selections, resolution) when is_list(selections) do
    Enum.flat_map(selections, &expand_selection(&1, resolution))
  end

  defp expand_selections(_, _), do: []

  defp expand_selection(%{flags: %{skip: _}}, _resolution), do: []

  defp expand_selection(%Absinthe.Blueprint.Document.Field{} = field, _resolution), do: [field]

  defp expand_selection(%Fragment.Spread{name: name}, resolution) do
    case Map.fetch(resolution.fragments, name) do
      {:ok, %{selections: inner}} -> expand_selections(inner, resolution)
      :error -> []
    end
  end

  defp expand_selection(%Fragment.Inline{selections: inner}, resolution) do
    expand_selections(inner, resolution)
  end

  defp expand_selection(_, _resolution), do: []

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    key
    |> Macro.underscore()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> String.to_atom(key)
  end

  defp list_item_module(result_module) do
    case Keyword.fetch(result_module.__schema__(), :items) do
      {:ok, {%ListOf{of_type: item_module}, _}} -> item_module
      _ -> nil
    end
  end
end
