defmodule Dobro.Schema.Input do
  @moduledoc """
  Normalises raw input before it is cast into a schema (contract or value
  object).

  Input often arrives with string keys (JSON from GraphQL, `jsonb` columns,
  event payloads). Top-level keys that name an existing atom are atomized so
  they match the schema's fields; other keys are kept as they are.
  """

  @doc """
  Atomizes a map's top-level string keys (structs are first turned into maps).

  Nested maps are left alone: `:map` fields (JSON blobs, assigns) keep their
  original keys, and nested schemas normalise their own input when cast.
  """
  @spec normalize(term()) :: term()
  def normalize(%DateTime{} = value), do: value
  def normalize(%NaiveDateTime{} = value), do: value
  def normalize(%Date{} = value), do: value
  def normalize(%Time{} = value), do: value

  def normalize(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> normalize()
  end

  def normalize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {atomize_key(key), value}
      {key, value} -> {key, value}
    end)
  end

  def normalize(other), do: other

  # Only existing atoms: never create atoms from input.
  defp atomize_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
