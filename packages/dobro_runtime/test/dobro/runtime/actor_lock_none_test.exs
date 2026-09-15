defmodule Dobro.Runtime.ActorLock.NoneTest do
  use ExUnit.Case, async: true

  alias Dobro.Runtime.ActorLock.None

  test "always acquires and never reports an owner" do
    assert :ok = None.try_acquire(:any_key, self())
    assert :ok = None.try_acquire(:any_key, spawn(fn -> :ok end))
    assert :unknown = None.whereis(:any_key)
    assert :ok = None.release(:any_key)
    assert [] = None.child_specs([])
  end
end
