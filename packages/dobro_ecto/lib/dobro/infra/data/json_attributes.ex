defmodule Dobro.Infra.Data.JsonAttributes do
  @moduledoc """
  Provides functionality for handling JSON attributes in data transfer objects (DTOs) during mapping between different data structures.
  This module is intended to be used within mappers to facilitate the extraction and insertion of JSON attributes from/to DTOs, allowing for flexible handling of dynamic or additional attributes that may not be explicitly defined in the domain model.
  """

  @doc """
  Retrieves the JSON attributes from a data transfer object (DTO). If no JSON attributes are present, it returns an empty map.
  """
  def get_json_attributes(dto) do
    Map.get(dto, :json_attributes, %{})
  end

  @doc """
  Retrieves a specific JSON attribute from a data transfer object (DTO) by key. If the attribute is not present, it returns nil.
  """
  def get_json_attribute(dto, key) do
    get_json_attributes(dto)
    |> Map.get(key)
  end

  @doc """
  Puts a specific JSON attribute into a data transfer object (DTO) under the :json_attributes key. It updates the existing JSON attributes map with the new key-value pair.
  """
  def put_json_attribute(dto, key, value) do
    json_attributes =
      get_json_attributes(dto)
      |> Map.put(key, value)

    Map.put(dto, :json_attributes, json_attributes)
  end

  defmacro __using__(opts \\ []) do
    keys = Keyword.get(opts, :keys, [])

    quote do
      unquote(functions(keys))
    end
  end

  def functions(keys) do
    quote do
      import Dobro.Infra.Data.JsonAttributes

      def json_attribute_keys, do: unquote(keys)

      def get_from_dto(dto, key) do
        if key in json_attribute_keys() do
          {:ok, get_json_attribute(dto, key)}
        else
          super(dto, key)
        end
      end

      def put_in_dto(dto, key, value) do
        if key in json_attribute_keys() do
          {:ok, put_json_attribute(dto, key, value)}
        else
          super(dto, key, value)
        end
      end
    end
  end
end
