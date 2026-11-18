defmodule Dobro.Contract.Helpers do
  @moduledoc """
  Builds and casts contract structs from input maps.
  """

  alias Dobro.Pipeline
  alias Dobro.Schema.Input

  import Dobro.Pipeline
  import Dobro.State

  @doc """
  Loads a persisted map into a contract struct without running validations.

  Used when rehydrating nested event / schema payloads from storage.
  """
  def load(_contract_module, nil), do: {:ok, nil}

  def load(contract_module, %{__struct__: contract_module} = value), do: {:ok, value}

  def load(contract_module, %{} = input) do
    Pipeline.new(
      state: %{value: %{}},
      input: Input.normalize(input),
      config: %{schema_module: contract_module}
    )
    |> hydrate_all()
    |> case do
      %{errors: []} = pipeline ->
        {:ok, struct(contract_module, pipeline.state.value)}

      %{errors: errors} ->
        {:error, errors}
    end
  end

  def load(_contract_module, _value), do: {:error, :invalid_load_input}

  @doc "Casts `value` into `contract_module`, returning `{:ok, struct}` or `{:error, errors}`."
  def new(contract_module, value) do
    Pipeline.new(
      state: %{value: Map.from_struct(struct(contract_module))},
      input: Input.normalize(value),
      config: %{schema_module: contract_module}
    )
    |> assign_all()
    |> then(&cast(contract_module, &1))
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
