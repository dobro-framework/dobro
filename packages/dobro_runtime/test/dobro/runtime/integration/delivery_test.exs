defmodule Dobro.Runtime.Integration.DeliveryTest do
  use ExUnit.Case, async: true

  alias Dobro.Runtime.Integration.Delivery

  defmodule WithWork do
    def __ack__, do: :with_work
    def handle(%{fail: true}), do: {:error, :nope}
    def handle(_event), do: :ok
  end

  defmodule AfterSuccess do
    def __ack__, do: :after_success
    def handle(%{fail: true}), do: {:error, :nope}
    def handle(event) do
      if event.opened, do: send(event.test_pid, :tx_open)
      :ok
    end
    def after_commit(_event), do: send(self(), :after_commit)
  end

  test "a with_work error leaves the cursor in place" do
    assert {:error, :nope} =
             Delivery.run(WithWork, %{id: "e1", fail: true},
               transaction: &tx/2,
               advance: fn -> send(self(), :advanced) end,
               record_failure: fn _ -> 1 end
             )

    refute_received :advanced
  end

  test "with_work advances inside the transaction" do
    assert :ok =
             Delivery.run(WithWork, %{id: "e1"},
               transaction: &tx/2,
               advance: fn ->
                 send(self(), :advanced)
                 :ok
               end
             )

    assert_received :advanced
  end

  test "after_success moves the cursor only after ok and runs outside a transaction" do
    assert :ok =
             Delivery.run(AfterSuccess, %{id: "e1", opened: false, test_pid: self()},
               transaction: fn fun, _opts ->
                 send(self(), :cursor_tx)
                 {:ok, fun.()}
               end,
               advance: fn -> :ok end
             )

    assert_received :cursor_tx
    assert_received :after_commit
  end

  test "after_success does not move the cursor on error" do
    assert {:error, :nope} =
             Delivery.run(AfterSuccess, %{id: "e1", fail: true},
               transaction: fn fun, _opts -> {:ok, fun.()} end,
               advance: fn -> send(self(), :advanced) end,
               record_failure: fn _ -> 1 end
             )

    refute_received :advanced
  end

  test "repeated failure dead-letters and later work can continue" do
    assert {:dead_letter, :nope} =
             Delivery.run(WithWork, %{id: "e1", fail: true, payload: %{}},
               transaction: &tx/2,
               advance: fn -> send(self(), :advanced) end,
               record_failure: fn _ -> 5 end,
               dead_letter: fn event, reason ->
                 send(self(), {:dead, event.id, reason})
                 :ok
               end,
               max_failures: 5
             )

    assert_received {:dead, "e1", :nope}
    assert_received :advanced
  end

  defmodule WithAfterCommitEffect do
    def __ack__, do: :with_work

    def handle(_event) do
      {:ok, after_commit: fn -> send(self(), :effect_ran) end}
    end
  end

  test "with_work runs returned after_commit effects only after commit" do
    assert :ok =
             Delivery.run(WithAfterCommitEffect, %{id: "e1"},
               transaction: &tx/2,
               advance: fn -> :ok end
             )

    assert_received :effect_ran
  end

  test "with_work does not run after_commit effects when handle fails" do
    assert {:error, :nope} =
             Delivery.run(WithWork, %{id: "e1", fail: true},
               transaction: fn fun, _opts ->
                 case fun.() do
                   {:ok, _} = ok -> ok
                   {:error, reason} -> {:error, reason}
                 end
               end,
               advance: fn -> send(self(), :advanced) end,
               record_failure: fn _ -> 1 end
             )

    refute_received :effect_ran
    refute_received :advanced
  end

  defp tx(fun, _opts) do
    case fun.() do
      {:ok, effects} -> {:ok, {:ok, effects}}
      {:error, reason} -> {:error, reason}
      :ok -> {:ok, {:ok, []}}
    end
  end
end
