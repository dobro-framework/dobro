defmodule Dobro.Schema.DomainValue do
  @moduledoc """
  Provides utilities for handling domain values during mapping between different data structures.
  This module is intended to be used within mappers to facilitate the conversion of values from data transfer objects (DTOs) to domain models and vice versa, especially when dealing with complex types such as lists and discriminated unions.
  """

  alias Dobro.Schema.{ListOf, NonNull, OneOf, Types}

  @doc """
  Converts a value from a data transfer object (DTO) to its corresponding domain value based on the specified type.
  This function handles basic types (string, integer, float, datetime) as well as complex types like lists and one-of discriminated unions.
  """
  def value_for(_value, nil), do: {:ok, nil}

  def value_for(nil, %ListOf{of_type: _}) do
    {:ok, []}
  end

  def value_for(value, %ListOf{of_type: of_type}) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case value_for(item, of_type) do
        {:ok, item_value} -> {:cont, {:ok, acc ++ [item_value]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def value_for(value, %NonNull{of_type: of_type}) do
    if null_value?(value) do
      {:error, :required}
    else
      value_for(value, of_type)
    end
  end

  def value_for(value, %OneOf{of_types: of_types, discr_fn: discr_fn}) do
    of_type = discr_fn.(value)

    if Enum.member?(of_types, of_type) do
      of_type.load(value)
    else
      IO.warn("Could not hydrate #{value} to one of #{of_types}")
      {:error, :could_not_hydrate}
    end
  end

  def value_for(value, type) when is_atom(type) do
    if type in Types.types() do
      {:ok, value}
    else
      type.load(value)
    end
  end

  def value_for(_value, type) do
    IO.warn("Unknown type #{inspect(type)} for value")
    {:error, :unknown_type}
  end

  @doc """
  Loads a persisted value into its domain representation without validations or invariants.

  Used when hydrating from the database or replaying events.
  """
  def load(_value, nil), do: {:ok, nil}

  def load(nil, %ListOf{of_type: _}) do
    {:ok, []}
  end

  def load(value, %ListOf{of_type: of_type}) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case load(item, of_type) do
        {:ok, item_value} -> {:cont, {:ok, acc ++ [item_value]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  def load(value, %NonNull{of_type: of_type}) do
    load(value, of_type)
  end

  def load(value, %OneOf{of_types: of_types, discr_fn: discr_fn}) do
    of_type = discr_fn.(value)

    if Enum.member?(of_types, of_type) do
      load(value, of_type)
    else
      {:error, :could_not_load}
    end
  end

  def load(value, type) when is_atom(type) do
    if type in Types.types() do
      {:ok, value}
    else
      type.load(value)
    end
  end

  def load(_value, type) do
    IO.warn("Unknown type #{inspect(type)} for value")
    {:error, :unknown_type}
  end

  def load!(value, type) do
    case load(value, type) do
      {:ok, value} -> value
      {:error, error} -> raise "Could not load value: #{inspect(error)}"
    end
  end

  def value_for!(value, type) do
    case value_for(value, type) do
      {:ok, value} -> value
      {:error, error} -> raise "Could not convert value: #{inspect(error)}"
    end
  end

  defp null_value?(nil), do: true
  defp null_value?(""), do: true
  defp null_value?(_), do: false
end
