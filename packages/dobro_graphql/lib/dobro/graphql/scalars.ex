defmodule Dobro.Graphql.Scalars do
  @moduledoc """
  Scalars shared by every Dobro GraphQL schema.

  `:json` accepts a JSON string and returns the decoded value. Output values
  pass through, so a map is serialized as a JSON object.
  """

  use Absinthe.Schema.Notation

  scalar :json, name: "Json" do
    description """
    The `Json` scalar type represents arbitrary JSON, represented as UTF-8
    character sequences.
    """

    serialize &encode/1
    parse &decode/1
  end

  defp decode(%Absinthe.Blueprint.Input.String{value: value}) do
    case Jason.decode(value) do
      {:ok, result} -> {:ok, result}
      _ -> :error
    end
  end

  defp decode(%Absinthe.Blueprint.Input.Null{}) do
    {:ok, nil}
  end

  defp decode(_), do: :error

  defp encode(value), do: value
end
