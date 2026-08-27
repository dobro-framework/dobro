defmodule Dobro.Domain.Id do
  @moduledoc """
  Generates unique identifiers for domain messages and entities.
  """

  @doc "Generates a new UUID v4 string."
  @spec generate() :: String.t()
  def generate do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)

    <<u0::48, 0::4, u1::12, 2::2, u2::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::8-binary, b::4-binary, c::4-binary, d::4-binary, e::12-binary>> ->
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end
end
