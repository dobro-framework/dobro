defmodule Dobro.Infra.Data.OutboxTest do
  use ExUnit.Case, async: true

  alias Dobro.Infra.Data.Outbox

  test "insert/2 is a no-op for an empty event list" do
    assert :ok = Outbox.insert("stream", [])
  end

  test "mark_processed/1 and release/1 are no-ops for empty lists" do
    assert :ok = Outbox.mark_processed([])
    assert :ok = Outbox.release([])
  end
end
