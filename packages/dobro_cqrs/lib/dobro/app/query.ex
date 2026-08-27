defmodule Dobro.App.Query do
  @moduledoc """
  Query macro
  """

  defmacro __using__(_opts) do
    quote do
      use Dobro.App.Schema
      import Dobro.App.Query
    end
  end

  defmacro payload(do: block) do
    quote do
      schema do
        unquote(block)
      end
    end
  end
end
