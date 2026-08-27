defmodule Dobro.Domain.Invariants.Helpers do
  @moduledoc """
  Runs declared invariant functions against aggregate or value object state.
  """

  alias Dobro.Error

  @doc "Returns `:ok` when all invariants pass, otherwise `{:error, %Error{}}`."
  def check_invariants(module, %{value: value}) do
    module.__invariants__()
    |> Enum.reduce_while(:ok, fn key, acc ->
      case apply(module, key, [value]) do
        :ok ->
          {:cont, acc}

        :error ->
          {:halt, {:error, Error.new(key)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}

        # `{:error, :code}` is a reason atom, not user-facing copy.
        {:error, reason} when is_atom(reason) ->
          {:halt, {:error, Error.new(reason)}}

        {:error, description} when is_binary(description) ->
          {:halt, {:error, Error.new(key, description: description)}}
      end
    end)
  end
end
