defmodule Dobro.Contract.HelpersTest do
  use ExUnit.Case, async: true

  alias Dobro.Contract.Helpers

  defmodule Timestamped do
    use Dobro.Schema

    schema do
      field :id, :id
      field :created_at, :datetime
    end

    def new(value), do: Helpers.new(__MODULE__, value)
  end

  test "casts datetime fields without breaking DateTime values" do
    created_at = ~U[2024-01-01 12:00:00Z]

    assert {:ok, result} =
             Timestamped.new(%{
               id: 1,
               created_at: created_at
             })

    assert result.created_at == created_at
  end
end
