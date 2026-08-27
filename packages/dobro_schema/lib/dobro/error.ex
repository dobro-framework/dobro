defmodule Dobro.Error do
  @moduledoc """
  Error struct for error handling
  """
  defstruct [:reason, :description, :path, :context]

  defp from_opts(opts) when is_list(opts) do
    validate_error_opts!(opts)

    %__MODULE__{
      reason: Keyword.fetch!(opts, :reason),
      path: Keyword.get(opts, :path),
      description: Keyword.get(opts, :description),
      context: Keyword.get(opts, :context)
    }
  end

  # ensure only valid keys are used in opts
  defp validate_error_opts!(opts) do
    valid_keys = [:reason, :description, :path, :context]
    invalid_keys = Keyword.keys(opts) -- valid_keys

    if invalid_keys != [] do
      raise ArgumentError, "Invalid keys in error options: #{inspect(invalid_keys)}"
    end
  end

  # Shorthand to create a new error struct with a reason
  def new(reason) when is_atom(reason) do
    from_opts(reason: reason)
  end

  def new(opts) when is_list(opts) do
    from_opts(opts)
  end

  def new(reason, opts) when is_atom(reason) and is_list(opts) do
    from_opts(Keyword.merge(opts, reason: reason))
  end

  def add(errors, error, opts \\ [])

  def add(errors, reason, opts) when is_atom(reason) and is_list(errors) do
    add(errors, new(reason), opts)
  end

  def add(errors, %__MODULE__{} = error, opts) when is_list(errors) do
    path_prefix = Keyword.get(opts, :path_prefix, nil)
    error = if path_prefix, do: %{error | path: merged_path(path_prefix, error.path)}, else: error
    errors ++ [error]
  end

  def merge(errors, error_to_merge, opts \\ [])

  def merge(errors, errors_to_merge, opts)
      when is_list(errors) and is_list(errors_to_merge) do
    Enum.reduce(errors_to_merge, errors, fn error, acc ->
      add(acc, error, opts)
    end)
  end

  def merge(errors, error_to_merge, opts)
      when is_list(errors) do
    add(errors, error_to_merge, opts)
  end

  defp merged_path(path_prefix, path) do
    [path_prefix, path] |> Enum.filter(& &1) |> Enum.join(".")
  end
end
