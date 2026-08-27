defmodule Dobro.Infra.Data.Mappings do
  @moduledoc """
  Declarative domain ↔ schema field and association mappings.

  Used by write repos (via generated mappers) and read repos (result projection).

  ## Field mappings

  Domain fields that live somewhere other than a same-named schema column:

      fields: [
        # renamed column
        display_name: :name,

        # value inside a map/embed column, same key
        abbreviation: {:in, :json_attributes},

        # value inside a map/embed column, different key
        phone: {:in, :json_attributes, :phone_number}
      ]

  ## Association mappings

  Domain id-lists backed by `has_many` (or similar) join rows:

      associations: [
        role_ids: {:role_links, :role_id}
      ]
  """

  @type field_mapping ::
          atom()
          | {:in, atom()}
          | {:in, atom(), atom()}

  @type association_mapping :: {atom(), atom()}

  @type t :: %{
          fields: %{optional(atom()) => field_mapping()},
          associations: %{optional(atom()) => association_mapping()}
        }

  @doc "Normalises keyword `mappings:` config into a map."
  @spec normalize(keyword() | t() | nil) :: t()
  def normalize(nil), do: empty()

  def normalize(mappings) when is_map(mappings) do
    %{
      fields: Map.new(Map.get(mappings, :fields, %{})),
      associations: Map.new(Map.get(mappings, :associations, %{}))
    }
  end

  def normalize(mappings) when is_list(mappings) do
    %{
      fields: Map.new(Keyword.get(mappings, :fields, [])),
      associations: Map.new(Keyword.get(mappings, :associations, []))
    }
  end

  @doc "Empty mappings."
  @spec empty() :: t()
  def empty, do: %{fields: %{}, associations: %{}}

  @doc "Association names that must be preloaded for `to_domain`."
  @spec preload_names(t()) :: [atom()]
  def preload_names(%{associations: associations}) do
    associations
    |> Map.values()
    |> Enum.map(fn {assoc, _fk} -> assoc end)
    |> Enum.uniq()
  end

  @doc """
  Returns true when `assoc` should be loaded for the given selection.

  An association is needed when it is selected directly, or when a domain field
  that maps from it (e.g. `role_ids` ← `:role_links`) is selected.
  """
  @spec association_selected?(atom(), Dobro.App.Selection.t() | nil, t()) :: boolean()
  def association_selected?(_assoc, nil, _mappings), do: true

  def association_selected?(assoc, %Dobro.App.Selection{} = selection, mappings) do
    Map.has_key?(selection.associations, assoc) or
      Enum.any?(mappings.associations, fn {domain_field, {mapped_assoc, _fk}} ->
        mapped_assoc == assoc and field_selected?(selection, domain_field)
      end)
  end

  @doc "Projects association-mapped domain fields onto a read result."
  @spec apply_to_result(term(), t()) :: term()
  def apply_to_result(result, %{associations: associations}) when map_size(associations) == 0,
    do: result

  def apply_to_result(result, %{associations: associations}) when is_map(result) do
    Enum.reduce(associations, result, fn {domain_field, {assoc, fk}}, acc ->
      Map.put(acc, domain_field, ids_from_assoc(Map.get(acc, assoc), fk))
    end)
  end

  def apply_to_result(result, _mappings), do: result

  @doc "Reads a domain field from a DTO using field mappings."
  @spec get_field(map(), atom(), field_mapping()) :: term()
  def get_field(dto, _domain_field, schema_field) when is_atom(schema_field) do
    Map.get(dto, schema_field)
  end

  def get_field(dto, domain_field, {:in, container}) do
    get_in_container(dto, container, domain_field)
  end

  def get_field(dto, _domain_field, {:in, container, key}) do
    get_in_container(dto, container, key)
  end

  @doc "Writes a domain field into a DTO using field mappings."
  @spec put_field(map(), atom(), term(), field_mapping()) :: map()
  def put_field(dto, _domain_field, value, schema_field) when is_atom(schema_field) do
    Map.put(dto, schema_field, value)
  end

  def put_field(dto, domain_field, value, {:in, container}) do
    put_in_container(dto, container, domain_field, value)
  end

  def put_field(dto, _domain_field, value, {:in, container, key}) do
    put_in_container(dto, container, key, value)
  end

  @doc "Reads an id-list domain field from an association on the DTO."
  @spec get_association(map(), association_mapping()) :: [term()]
  def get_association(dto, {assoc, fk}) do
    ids_from_assoc(Map.get(dto, assoc), fk)
  end

  @doc "Writes an id-list domain field as association attrs on the DTO."
  @spec put_association(map(), [term()], association_mapping()) :: map()
  def put_association(dto, ids, {assoc, fk}) when is_list(ids) do
    Map.put(dto, assoc, Enum.map(ids, fn id -> %{fk => id} end))
  end

  @doc "Extracts foreign-key values from association rows."
  @spec ids_from_assoc(term(), atom()) :: [term()]
  def ids_from_assoc(%Ecto.Association.NotLoaded{}, _fk), do: []
  def ids_from_assoc(nil, _fk), do: []

  def ids_from_assoc(rows, fk) when is_list(rows) do
    Enum.map(rows, fn
      %{} = row -> Map.get(row, fk)
      other -> other
    end)
  end

  defp get_in_container(dto, container, key) do
    case Map.get(dto, container) do
      nil -> nil
      %Ecto.Association.NotLoaded{} -> nil
      value -> container_get(value, key)
    end
  end

  defp put_in_container(dto, container, key, value) do
    current =
      case Map.get(dto, container) do
        nil -> %{}
        %Ecto.Association.NotLoaded{} -> %{}
        other -> container_to_map(other)
      end

    Map.put(dto, container, Map.put(current, key, value))
  end

  defp container_get(value, key) when is_map(value) do
    Map.get(value, key) || Map.get(value, Atom.to_string(key))
  end

  defp container_get(_value, _key), do: nil

  defp container_to_map(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id])
  end

  defp container_to_map(map) when is_map(map), do: map
  defp container_to_map(_), do: %{}

  defp field_selected?(%Dobro.App.Selection{fields: fields}, field) do
    MapSet.size(fields) == 0 or MapSet.member?(fields, field)
  end
end
