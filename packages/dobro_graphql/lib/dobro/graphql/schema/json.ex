defmodule Dobro.Graphql.Schema.JSON do
  @moduledoc """
  Normalises JSON mapping field structures for GraphQL input and output.
  """

  @doc "Converts mapping field input to a list of `%{from: ..., to: ...}` maps."
  def normalize_mapping(nil), do: []

  def normalize_mapping(list) when is_list(list) do
    Enum.map(list, fn
      %{from: from, to: to} ->
        %{from: from, to: to}

      %{"from" => from, "to" => to} ->
        %{from: from, to: to}
    end)
  end
end
