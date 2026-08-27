defmodule Dobro.App.ResultCaster do
  @moduledoc """
  Casts raw handler results to the typed result modules declared on API routes.
  """

  alias Dobro.App.DataTransfer.DTO
  alias Dobro.Schema.ListOf

  @doc """
  Casts a raw handler result to a typed result module (query/command `__result__/0`
  or an API route override).
  """
  @spec cast(term(), term()) :: {:ok, term()} | {:error, term()}
  def cast(value, result_mod) do
    cond do
      is_nil(result_mod) -> {:ok, value}
      castable_module?(result_mod) -> cast_module(value, result_mod)
      list_of_castable_module?(result_mod, value) -> cast_list(value, result_mod)
      true -> {:ok, value}
    end
  end

  @doc """
  Casts a handler payload using `message_module.__result__/0` when defined.
  """
  @spec cast_message_result(module(), term()) :: {:ok, term()} | {:error, term()}
  def cast_message_result(message_module, value) do
    result_mod =
      if function_exported?(message_module, :__result__, 0),
        do: message_module.__result__()

    cast(value, result_mod)
  end

  defp castable_module?(result_mod) when is_atom(result_mod) do
    match?({:module, _}, Code.ensure_loaded(result_mod)) and
      function_exported?(result_mod, :new, 1)
  end

  defp castable_module?(_result_mod), do: false

  defp list_of_castable_module?(%ListOf{of_type: of_type}, value) do
    is_list(value) and castable_module?(of_type)
  end

  defp list_of_castable_module?(_result_mod, _value), do: false

  defp cast_module(%mod{} = value, result_mod) when mod == result_mod, do: {:ok, value}

  defp cast_module(value, result_mod) do
    # Aggregates may embed value objects; convert to plain DTOs first so
    # primitive result fields (e.g. :string email) can cast cleanly.
    case result_mod.new(DTO.to_dto(value)) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
      false -> {:ok, value}
    end
  end

  defp cast_list(value, %ListOf{of_type: of_type}) do
    value
    |> Enum.reduce_while({:ok, []}, &cast_list_item(&1, &2, of_type))
    |> finalize_list()
  end

  defp cast_list_item(item, {:ok, acc}, of_type) do
    case of_type.new(DTO.to_dto(item)) do
      {:ok, casted} -> {:cont, {:ok, [casted | acc]}}
      {:error, error} -> {:halt, {:error, error}}
      _ -> {:halt, {:error, {:invalid_cast, item}}}
    end
  end

  defp finalize_list({:ok, casted_rev}), do: {:ok, Enum.reverse(casted_rev)}
  defp finalize_list(error), do: error
end
