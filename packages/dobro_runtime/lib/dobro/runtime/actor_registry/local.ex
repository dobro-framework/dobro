defmodule Dobro.Runtime.ActorRegistry.Local do
  @moduledoc """
  Local OTP `Registry` adapter for Dobro runtime actors.
  """

  @behaviour Dobro.Runtime.ActorRegistry

  @registry Dobro.Runtime.Registry

  @impl true
  def lookup(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> :miss
    end
  end

  @impl true
  def via(key), do: {:via, Registry, {@registry, key}}
end
