defmodule Dobro.Infra.Data.IntegrationOutboxTest do
  use ExUnit.Case, async: true

  alias Dobro.Infra.Data.IntegrationOutbox

  test "cast_occurred_at!/1 keeps DateTime values at usec precision" do
    dt = ~U[2026-11-05 10:30:20.123456Z]

    assert %DateTime{microsecond: {123_456, 6}} = IntegrationOutbox.cast_occurred_at!(dt)
  end

  test "cast_occurred_at!/1 parses ISO8601 strings including truncated Z forms" do
    assert %DateTime{
             year: 2026,
             month: 11,
             day: 5,
             hour: 10,
             minute: 30,
             second: 20,
             microsecond: {0, 6}
           } = IntegrationOutbox.cast_occurred_at!("2026-11-05T10:30:20Z")
  end

  test "cast_occurred_at!/1 rejects unparseable values" do
    assert_raise ArgumentError, ~r/invalid occurred_at/, fn ->
      IntegrationOutbox.cast_occurred_at!("not-a-datetime")
    end

    assert_raise ArgumentError, ~r/invalid occurred_at/, fn ->
      IntegrationOutbox.cast_occurred_at!(42)
    end
  end
end
