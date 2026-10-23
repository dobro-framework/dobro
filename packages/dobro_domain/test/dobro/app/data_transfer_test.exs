defmodule Dobro.App.DataTransferTest do
  use ExUnit.Case, async: true

  alias Dobro.App.DataTransfer.DTO

  test "keeps Date and Time structs intact" do
    date = ~D[2026-11-01]
    time = ~T[12:30:00]

    assert DTO.to_dto(date) == date
    assert DTO.to_dto(time) == time
  end

  test "keeps Date fields inside nested maps" do
    assert DTO.to_dto(%{due_on: ~D[2026-11-01], description: "Call"}) == %{
             due_on: ~D[2026-11-01],
             description: "Call"
           }
  end
end
