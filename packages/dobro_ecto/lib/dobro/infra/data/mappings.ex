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

  Full associated values (e.g. `list_of` child entities) use a bare assoc name:

      associations: [
        lines: :order_lines
      ]

  For bare-atom mappings, Dobro shapes row attrs only — the schema changeset should
  `cast_assoc/2` (typically with `on_replace: :delete`) so inserts/updates/orphans
  sync by child primary key. Align the entity `identity:` field with that PK (or
  map it via field mappings).
  """

  @type field_mapping ::
          atom()
          | {:in, atom()}
          | {:in, atom(), atom()}

  @type association_mapping :: atom() | {atom(), atom()}

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
    |> Enum.map(&assoc_name/1)
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
      Enum.any?(mappings.associations, fn {domain_field, mapping} ->
        assoc_name(mapping) == assoc and field_selected?(selection, domain_field)
      end)
  end

  @doc """
  Projects id-list association mappings onto a read result.

  Bare-atom (full entity) mappings are skipped — the domain field already holds
  full values from write/query mapping.
  """
  @spec apply_to_result(term(), t()) :: term()
  def apply_to_result(result, %{associations: associations}) when map_size(associations) == 0,
    do: result

  def apply_to_result(result, %{associations: associations}) when is_map(result) do
    Enum.reduce(associations, result, fn
      {domain_field, {assoc, fk}}, acc ->
        Map.put(acc, domain_field, ids_from_assoc(Map.get(acc, assoc), fk))

      {_domain_field, assoc}, acc when is_atom(assoc) ->
        acc
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

  @doc """
  Reads a domain association field from the DTO.

  - `{assoc, fk}` — id-list extracted from association rows
  - `assoc` (bare atom) — full row maps for DomainValue / entity `load`
  """
  @spec get_association(map(), association_mapping()) :: [term()]
  def get_association(dto, {assoc, fk}) do
    ids_from_assoc(Map.get(dto, assoc), fk)
  end

  def get_association(dto, assoc) when is_atom(assoc) do
    rows_from_assoc(Map.get(dto, assoc))
  end

  @doc """
  Writes a domain association field as association attrs on the DTO.

  - `{assoc, fk}` — id-list becomes `[%{fk => id}, ...]`
  - `assoc` (bare atom) — entity/struct list becomes plain attr maps (via DTO)
  """
  @spec put_association(map(), [term()], association_mapping()) :: map()
  def put_association(dto, ids, {assoc, fk}) when is_list(ids) do
    Map.put(dto, assoc, Enum.map(ids, fn id -> %{fk => id} end))
  end

  def put_association(dto, values, assoc) when is_atom(assoc) and is_list(values) do
    Map.put(dto, assoc, Enum.map(values, &dump_assoc_row/1))
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

  defp assoc_name({assoc, _fk}) when is_atom(assoc), do: assoc
  defp assoc_name(assoc) when is_atom(assoc), do: assoc

  defp rows_from_assoc(%Ecto.Association.NotLoaded{}), do: []
  defp rows_from_assoc(nil), do: []
  defp rows_from_assoc(rows) when is_list(rows), do: Enum.map(rows, &row_attrs/1)

  defp dump_assoc_row(%{__struct__: mod} = struct) do
    if function_exported?(mod, :value, 1) do
      mod.value(struct)
    else
      Dobro.App.DataTransfer.DTO.to_dto(struct)
    end
  end

  defp dump_assoc_row(%{} = map), do: map
  defp dump_assoc_row(other), do: other

  defp row_attrs(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
  end

  defp row_attrs(%{} = map), do: Map.drop(map, [:__meta__])
  defp row_attrs(other), do: other

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
