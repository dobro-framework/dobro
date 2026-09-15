defmodule Dobro.Runtime.ActorLock.MemoryTest do
  use ExUnit.Case, async: false

  alias Dobro.Runtime.ActorLock.Memory

  setup do
    case GenServer.whereis(Memory) do
      nil -> start_supervised!(Memory)
      _pid -> :ok
    end

    on_exit(fn ->
      # Best-effort cleanup between tests
      try do
        Memory.release(:test_key)
        Memory.release(:test_key_2)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "exclusive acquire" do
    assert :ok = Memory.try_acquire(:test_key, self())
    assert {:error, :locked} = Memory.try_acquire(:test_key, spawn(fn -> :ok end))
    assert {:ok, pid} = Memory.whereis(:test_key)
    assert pid == self()
    assert :ok = Memory.release(:test_key)
    assert :unknown = Memory.whereis(:test_key)
  end

  test "releases when owner dies" do
    parent = self()

    owner =
      spawn(fn ->
        :ok = Memory.try_acquire(:test_key_2, self())
        send(parent, :locked)
        receive do
          :die -> :ok
        end
      end)

    assert_receive :locked
    assert {:ok, ^owner} = Memory.whereis(:test_key_2)
    Process.exit(owner, :kill)
    Process.sleep(50)
    assert :unknown = Memory.whereis(:test_key_2)
  end
end
