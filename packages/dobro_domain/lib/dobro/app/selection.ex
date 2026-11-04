defmodule Dobro.App.Selection do
  @moduledoc """
  Normalized field selection for query results.

  Produced by GraphQL (or other transports) and consumed by read repositories.
  When `nil`, repositories fetch all declared fields.
  """

  use TypedStruct

  alias Dobro.Schema.{ListOf, NonNull, Types}

  typedstruct do
    field(:fields, MapSet.t(), default: MapSet.new())
    field(:associations, %{optional(atom()) => t()}, default: %{})
    # Pagination meta fields requested by GraphQL. Empty does not skip COUNT —
    # list queries always compute total_count unless spec.count is :skip.
    field(:meta_fields, MapSet.t(), default: MapSet.new())
  end

  @doc "True when a GraphQL list selection requested total_count or total_pages."
  @spec total_count_selected?(t() | nil) :: boolean()
  def total_count_selected?(nil), do: true

  def total_count_selected?(%__MODULE__{meta_fields: meta}) do
    MapSet.member?(meta, :total_count) or MapSet.member?(meta, :total_pages)
  end

  @doc "Returns all fields when selection is nil."
  def selected_fields(nil, all_fields), do: MapSet.new(all_fields)

  def selected_fields(%__MODULE__{fields: %MapSet{} = fields}, all_fields) do
    if MapSet.size(fields) > 0, do: fields, else: MapSet.new(all_fields)
  end

  @doc "Builds a selection from a normalized projection map and result contract module."
  @spec from_projection(map(), module()) :: t()
  def from_projection(projected, result_module) do
    schema = result_module.__schema__()
    fields = scalar_fields(projected, schema)
    associations = association_fields(projected, schema)
    %__MODULE__{fields: fields, associations: associations}
  end

  defp scalar_fields(projected, schema) do
    selected =
      schema
      |> Enum.filter(fn {name, _} -> scalar_type?(schema, name) end)
      |> Enum.reduce(MapSet.new(), fn {name, _}, acc ->
        case Map.get(projected, name) do
          nil -> acc
          _ -> MapSet.put(acc, name)
        end
      end)

    if MapSet.size(selected) == 0 do
      schema
      |> Enum.filter(fn {name, _} -> scalar_type?(schema, name) end)
      |> Enum.map(fn {name, _} -> name end)
      |> MapSet.new()
    else
      selected
    end
  end

  defp association_fields(projected, schema) do
    Enum.reduce(schema, %{}, fn {name, {type, _}}, acc ->
      if association_type?(type) do
        case Map.get(projected, name) do
          nested when is_map(nested) ->
            Map.put(acc, name, from_projection(nested, association_module(type)))

          _ ->
            acc
        end
      else
        acc
      end
    end)
  end

  defp scalar_type?(schema, name) do
    case Keyword.get(schema, name) do
      {type, _} -> not association_type?(type)
      _ -> true
    end
  end

  # list_of(scalar) stays a scalar; list_of(contract/module) is an association
  # (preload / nested GraphQL selection), same as a singular nested contract.
  defp association_type?(%ListOf{of_type: of_type}), do: association_type?(unwrap_type(of_type))

  defp association_type?(%NonNull{of_type: of_type}), do: association_type?(of_type)

  defp association_type?(type) when is_atom(type) do
    cond do
      Types.type_exists?(type) -> false
      # Enums are leaf scalars; without this they look like unknown modules and are
      # dropped when GraphQL selects them as leaves (breaking OneOfBy controllers).
      enum_type?(type) -> false
      true -> true
    end
  end

  defp association_type?(_), do: false

  defp association_module(%ListOf{of_type: of_type}), do: association_module(unwrap_type(of_type))
  defp association_module(%NonNull{of_type: of_type}), do: association_module(of_type)
  defp association_module(type) when is_atom(type), do: type

  defp unwrap_type(%NonNull{of_type: of_type}), do: of_type
  defp unwrap_type(type), do: type

  defp enum_type?(type) do
    match?({:module, _}, Code.ensure_loaded(type)) and Dobro.Enum.enum?(type)
  end
end

