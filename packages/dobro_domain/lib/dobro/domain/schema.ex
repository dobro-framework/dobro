defmodule Dobro.Domain.Schema do
  @moduledoc """
  Macro for Domain Model schemas
  """

  defmacro __using__(_opts) do
    quote do
      use Dobro.Schema
      use Dobro.Domain.Invariants
    end
  end
end
