defmodule Dobro.Contract.Helpers do
  @moduledoc """
  Builds and casts contract structs from input maps.
  """

  alias Dobro.Pipeline

  import Dobro.Pipeline
  import Dobro.State

  @doc "Casts `value` into `contract_module`, returning `{:ok, struct}` or `{:error, errors}`."
  def new(contract_module, value) do
    Pipeline.new(
      state: %{value: Map.from_struct(struct(contract_module))},
      input: normalize_input(value),
      config: %{schema_module: contract_module}
    )
    |> assign_all()
    |> then(&cast(contract_module, &1))
  end

  defp normalize_input(%DateTime{} = value), do: value
  defp normalize_input(%NaiveDateTime{} = value), do: value
  defp normalize_input(%Date{} = value), do: value
  defp normalize_input(%Time{} = value), do: value

  # Atomize this contract's own field names. Do not walk into nested maps —
  # `:map` fields (JSON blobs, assigns) must keep their original keys, and nested
  # contracts atomize their own fields when `type.new/1` runs.
  defp normalize_input(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> normalize_input()
  end

  defp normalize_input(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {atomize_key(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_input(other), do: other

  defp atomize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  @doc "Casts `value` into `contract_module`, raising when validation fails."
  def new!(contract_module, value) do
    case new(contract_module, value) do
      {:ok, result} -> result
      {:error, error} -> raise "Failed to create #{inspect(contract_module)}: #{inspect(error)}"
    end
  end

  @doc "Materialises a contract struct from a validated pipeline."
  def cast(contract_module, %Pipeline{} = pipeline) do
    pipeline
    |> validate(contract_module.__schema__())
    |> bind(fn pipeline ->
      put_in(pipeline.state, %{
        pipeline.state
        | value: struct(contract_module, pipeline.state.value)
      })
    end)
    |> finalize(:value)
  end
end
