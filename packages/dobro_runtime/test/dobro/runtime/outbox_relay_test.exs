defmodule Dobro.Runtime.OutboxRelayTest do
  use ExUnit.Case, async: false

  alias Dobro.Runtime.OutboxRelay

  setup do
    previous = Application.get_env(:dobro_runtime, :outbox_relay)

    Application.put_env(:dobro_runtime, :outbox_relay,
      batch_size: 25,
      poll_interval_ms: 60_000,
      purge_after_ms: 86_400_000,
      purge_interval_ms: 60_000
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:dobro_runtime, :outbox_relay, previous)
      else
        Application.delete_env(:dobro_runtime, :outbox_relay)
      end
    end)

    :ok
  end

  test "merges application config into server state" do
    name = :"outbox_relay_test_#{System.unique_integer([:positive])}"
    assert {:ok, pid} = OutboxRelay.start_link(name: name)

    state = :sys.get_state(pid)
    assert state[:batch_size] == 25
    assert state[:poll_interval_ms] == 60_000
    assert state[:purge_after_ms] == 86_400_000

    GenServer.stop(pid)
  end

  test "start_link opts override application config" do
    name = :"outbox_relay_test_#{System.unique_integer([:positive])}"
    assert {:ok, pid} = OutboxRelay.start_link(name: name, batch_size: 10)

    state = :sys.get_state(pid)
    assert state[:batch_size] == 10

    GenServer.stop(pid)
  end
end
