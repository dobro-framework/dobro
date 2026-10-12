defmodule Dobro.Schema.DomainValue do
  @moduledoc """
  Provides utilities for handling domain values during mapping between different data structures.
  This module is intended to be used within mappers to facilitate the conversion of values from data transfer objects (DTOs) to domain models and vice versa, especially when dealing with complex types such as lists and discriminated unions.
  """

  alias Dobro.Schema.{ListOf, NonNull, OneOf, OneOfBy, Types}

  defp resolve_type(type) when is_atom(type) do
    cond do
      OneOf.one_of?(type) -> type.__one_of__()
      OneOfBy.one_of_by?(type) -> type.__one_of_by__()
      true -> type
    end
  end

  @doc """
  Converts a value from a data transfer object (DTO) to its corresponding domain value based on the specified type.
  This function handles basic types (string, integer, float, datetime) as well as complex types like lists and one-of discriminated unions.
  """
  def value_for(value, type), do: value_for(value, type, nil)

  def value_for(_value, nil, _parent), do: {:ok, nil}

  def value_for(nil, %ListOf{of_type: _}, _parent) do
    {:ok, []}
  end

  def value_for(value, %ListOf{of_type: of_type}, parent) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case value_for(item, of_type, parent) do
        {:ok, item_value} -> {:cont, {:ok, acc ++ [item_value]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def value_for(value, %NonNull{of_type: of_type}, parent) do
    if null_value?(value) do
      {:error, :required}
    else
      value_for(value, of_type, parent)
    end
  end

  def value_for(value, %OneOf{of_types: of_types, discr_fn: discr_fn}, _parent) do
    of_type = discr_fn.(value)

    if Enum.member?(of_types, of_type) do
      of_type.load(value)
    else
      IO.warn("Could not hydrate #{value} to one of #{of_types}")
      {:error, :could_not_hydrate}
    end
  end

  def value_for(value, %OneOfBy{} = one_of_by, parent) do
    with {:ok, of_type} <- OneOfBy.resolve_member(one_of_by, parent || %{}) do
      of_type.load(value)
    else
      {:error, _} ->
        IO.warn("Could not hydrate #{inspect(value)} via OneOfBy")
        {:error, :could_not_hydrate}
    end
  end

  def value_for(value, type, parent) when is_atom(type) do
    case resolve_type(type) do
      ^type ->
        if type in Types.types() do
          {:ok, value}
        else
          type.load(value)
        end

      resolved ->
        value_for(value, resolved, parent)
    end
  end

  def value_for(_value, type, _parent) do
    IO.warn("Unknown type #{inspect(type)} for value")
    {:error, :unknown_type}
  end

  @doc """
  Loads a persisted value into its domain representation without validations or invariants.

  Used when hydrating from the database or replaying events.

  For `OneOfBy`, pass `parent` (sibling fields) so the controller field can resolve
  the member type.
  """
  def load(value, type), do: load(value, type, nil)

  def load(_value, nil, _parent), do: {:ok, nil}

  def load(nil, %ListOf{of_type: _}, _parent) do
    {:ok, []}
  end

  def load(value, %ListOf{of_type: of_type}, parent) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case load(item, of_type, parent) do
        {:ok, item_value} -> {:cont, {:ok, acc ++ [item_value]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def load(value, %NonNull{of_type: of_type}, parent) do
    load(value, of_type, parent)
  end

  def load(value, %OneOf{of_types: of_types, discr_fn: discr_fn}, _parent) do
    of_type = discr_fn.(value)

    if Enum.member?(of_types, of_type) do
      load(value, of_type, nil)
    else
      {:error, :could_not_load}
    end
  end

  def load(value, %OneOfBy{} = one_of_by, parent) do
    with {:ok, of_type} <- OneOfBy.resolve_member(one_of_by, parent || %{}),
         {:ok, loaded} <- load(value, of_type, parent) do
      {:ok, loaded}
    else
      {:error, _} = err -> err
    end
  end

  def load(value, type, parent) when is_atom(type) do
    cond do
      OneOfBy.one_of_by?(type) and function_exported?(type, :load, 2) ->
        type.load(value, parent)

      OneOf.one_of?(type) and function_exported?(type, :load, 1) ->
        type.load(value)

      true ->
        case resolve_type(type) do
          ^type ->
            if type in Types.types() do
              {:ok, value}
            else
              type.load(value)
            end

          resolved ->
            load(value, resolved, parent)
        end
    end
  end

  def load(_value, type, _parent) do
    IO.warn("Unknown type #{inspect(type)} for value")
    {:error, :unknown_type}
  end

  def load!(value, type), do: load!(value, type, nil)

  def load!(value, type, parent) do
    case load(value, type, parent) do
      {:ok, value} -> value
      {:error, error} -> raise "Could not load value: #{inspect(error)}"
    end
  end

  def value_for!(value, type), do: value_for!(value, type, nil)

  def value_for!(value, type, parent) do
    case value_for(value, type, parent) do
      {:ok, value} -> value
      {:error, error} -> raise "Could not convert value: #{inspect(error)}"
    end
  end

  defp null_value?(nil), do: true
  defp null_value?(""), do: true
  defp null_value?(_), do: false
end
