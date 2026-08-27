defmodule Dobro.Transformations do
  @moduledoc """
  Module for transforming data
  """

  @doc """
  Atomifies the keys of the input map
  """
  def atomify_keys(%{} = input) do
    input
    |> Jason.encode!()
    |> Jason.decode!(keys: :atoms!)
  end
end
