defmodule Dobro.Pipeline do
  @moduledoc """
  Pipeline module to manage state and errors during pipeline execution
  A pipeline is a sequence of functions that are applied to the input in order
  to produce a result.

  The pipeline is represented by a struct with the following fields:
  - state: the current state of the pipeline
  - original: the original state of the pipeline
  - input: the input to the pipeline
  - config: the configuration of the pipeline
  - errors: the errors that have occurred during the pipeline execution
  """
  @type t :: %__MODULE__{}

  defstruct state: nil,
            original: nil,
            input: %{},
            config: %{},
            errors: []

  @doc """
  Creates a new pipeline with the given state, input, and configuration
  """
  def new(state: state, input: input, config: config) do
    %__MODULE__{state: state, original: state, input: input, config: config}
  end

  def new, do: %__MODULE__{}

  @doc """
  Binds a function to the pipeline - provides monadic bind functionality
  """
  def bind(%{errors: []} = pipeline, fun), do: fun.(pipeline)
  def bind(%{} = pipeline, _fun), do: pipeline

  @doc """
  Finalizes the pipeline - returns the pipeline state as a tuple with :ok and the key if provided
  or a tuple with :error and the errors if there are any
  """
  def finalize(%{errors: []} = pipeline), do: {:ok, pipeline}
  def finalize(pipeline, key \\ nil)

  def finalize(%{errors: []} = pipeline, key) when is_atom(key) do
    {:ok, Map.get(pipeline.state, key)}
  end

  def finalize(%{errors: []} = pipeline, keys) when is_list(keys) do
    {:ok, Map.take(pipeline.state, keys)}
  end

  def finalize(%{errors: _} = pipeline, _key), do: {:error, pipeline.errors}

  @doc """
  Puts the input into the pipeline
  """
  def put_input(%{} = pipeline, %{} = input) do
    %{pipeline | input: input}
  end

  @doc """
  Adds an error to the pipeline
  """
  def add_error(%{} = pipeline, error, opts \\ []) do
    %{pipeline | errors: Dobro.Error.add(pipeline.errors, error, opts)}
  end

  @doc """
  Merges errors into the pipeline
  """
  def merge_errors(%{} = pipeline, errors, opts \\ []) do
    %{pipeline | errors: Dobro.Error.merge(pipeline.errors, errors, opts)}
  end
end
