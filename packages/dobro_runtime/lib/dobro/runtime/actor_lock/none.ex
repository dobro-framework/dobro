defmodule Dobro.Runtime.ActorLock.None do
  @moduledoc """
  No-op lock for single-node / test environments.

  `try_acquire/2` always succeeds. `whereis/1` always returns `:unknown`.
  """

  @behaviour Dobro.Runtime.ActorLock

  @impl true
  def try_acquire(_key, _owner), do: :ok

  @impl true
  def release(_key), do: :ok

  @impl true
  def whereis(_key), do: :unknown

  @doc false
  def child_specs(_opts), do: []
end
