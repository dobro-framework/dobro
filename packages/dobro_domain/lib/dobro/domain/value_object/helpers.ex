defmodule Dobro.Domain.ValueObject.Helpers do
  @moduledoc """
  Casting, loading, and comparison helpers for value objects.
  """

  alias Dobro.Domain.ValueObject.State
  alias Dobro.Pipeline

  import Dobro.Pipeline
  import Dobro.State

  @doc "Initialises a value-object pipeline from raw input."
  def transition(value_object_module, input) do
    config = %{schema_module: value_object_module}
    state = %State{}

    Pipeline.new(state: state, input: input, config: config)
  end

  @doc """
  Loads a persisted value into a value object struct without running validations or invariants.
  """
  def load(_value_object_module, nil), do: {:ok, nil}

  def load(value_object_module, %{__struct__: value_object_module} = value), do: {:ok, value}

  def load(value_object_module, %{} = input) do
    transition(value_object_module, input)
    |> hydrate_all()
    |> case do
      %{errors: []} = pipeline ->
        {:ok, struct(value_object_module, pipeline.state.value)}

      %{errors: errors} ->
        {:error, errors}
    end
  end

  def load(value_object_module, value) when is_binary(value) do
    if singular_value_object?(value_object_module) do
      load(value_object_module, %{value: value})
    else
      {:error, :invalid_load_input}
    end
  end

  @doc "Loads a persisted value, raising when hydration fails."
  def load!(value_object_module, value) do
    case load(value_object_module, value) do
      {:ok, result} -> result
      {:error, error} -> raise "Failed to load value object: #{inspect(error)}"
    end
  end

  @doc "Casts input into a value object, returning `{:ok, struct}` or `{:error, errors}`."
  def new(value_object_module, %{} = input) do
    transition(value_object_module, input)
    |> assign_all()
    |> then(&cast(value_object_module, &1))
  end

  @doc "Validates and materialises a value object from an in-progress pipeline."
  def cast(value_object_module, %Pipeline{} = pipeline) do
    pipeline
    |> validate(value_object_module.__schema__())
    |> precondition(fn state -> value_object_module.check_invariants(state) end)
    |> bind(fn pipeline ->
      put_in(pipeline.state, %{
        pipeline.state
        | value: struct(value_object_module, pipeline.state.value)
      })
    end)
    |> finalize(:value)
  end

  @doc "Formats a value object's extracted data for string conversion."
  @spec stringify(term()) :: String.t()
  def stringify(value) when is_binary(value), do: value
  def stringify(value) when is_integer(value), do: Integer.to_string(value)
  def stringify(value) when is_float(value), do: Float.to_string(value)
  def stringify(value) when is_atom(value), do: Atom.to_string(value)
  def stringify(value) when is_list(value), do: Enum.map_join(value, ",", &stringify/1)
  def stringify(value), do: inspect(value, structs: false)

  @doc "Returns the value object's field map, or `nil` when the value object is nil."
  def value(%_{} = vo), do: Map.from_struct(vo)
  def value(nil), do: nil

  @doc "Compares two value objects of the same type by their field maps."
  def equal?(%{__struct__: mod} = a, %{__struct__: mod} = b), do: value(a) == value(b)

  defp singular_value_object?(type) do
    Code.ensure_loaded?(type) and function_exported?(type, :singular?, 0) and type.singular?()
  end
end
