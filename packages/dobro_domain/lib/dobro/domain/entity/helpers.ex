defmodule Dobro.Domain.Entity.Helpers do
  @moduledoc """
  Casting, loading, and identity comparison helpers for entities.
  """

  alias Dobro.Domain.Entity.State
  alias Dobro.Pipeline

  import Dobro.Pipeline
  import Dobro.State

  @doc "Initialises an entity pipeline from raw input."
  def transition(entity_module, input) do
    config = %{schema_module: entity_module}
    state = %State{}

    Pipeline.new(state: state, input: input, config: config)
  end

  @doc """
  Loads a persisted value into an entity struct without running validations or invariants.
  """
  def load(_entity_module, nil), do: {:ok, nil}

  def load(entity_module, %{__struct__: entity_module} = value), do: {:ok, value}

  def load(entity_module, %{} = input) do
    transition(entity_module, input)
    |> hydrate_all()
    |> case do
      %{errors: []} = pipeline ->
        {:ok, struct(entity_module, pipeline.state.value)}

      %{errors: errors} ->
        {:error, errors}
    end
  end

  def load(_entity_module, _value), do: {:error, :invalid_load_input}

  @doc "Loads a persisted value, raising when hydration fails."
  def load!(entity_module, value) do
    case load(entity_module, value) do
      {:ok, result} -> result
      {:error, error} -> raise "Failed to load entity: #{inspect(error)}"
    end
  end

  @doc "Casts input into an entity, returning `{:ok, struct}` or `{:error, errors}`."
  def new(entity_module, %{} = input) do
    identity_field = entity_module.__identity_field__()

    # Identity is immutable for assign/2, but may be set once on create via hydrate.
    transition(entity_module, input)
    |> assign_all()
    |> hydrate([identity_field])
    |> then(&cast(entity_module, &1))
  end

  @doc "Validates and materialises an entity from an in-progress pipeline."
  def cast(entity_module, %Pipeline{} = pipeline) do
    pipeline
    |> validate(entity_module.__schema__())
    |> precondition(fn state -> entity_module.check_invariants(state) end)
    |> bind(fn pipeline ->
      put_in(pipeline.state, %{
        pipeline.state
        | value: struct(entity_module, pipeline.state.value)
      })
    end)
    |> finalize(:value)
  end

  @doc "Returns the entity's field map, or `nil` when the entity is nil."
  def value(%_{} = entity), do: Map.from_struct(entity)
  def value(nil), do: nil

  @doc "Compares two entities of the same type by their identity field."
  def equal?(%{__struct__: mod} = a, %{__struct__: mod} = b) do
    field = mod.__identity_field__()
    Map.get(a, field) == Map.get(b, field) and not is_nil(Map.get(a, field))
  end

  def equal?(_, _), do: false

  @doc "Returns the entity's identity value."
  def identity(%{__struct__: mod} = entity) do
    Map.fetch!(entity, mod.__identity_field__())
  end
end
