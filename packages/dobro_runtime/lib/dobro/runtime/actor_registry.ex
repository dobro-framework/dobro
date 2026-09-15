defmodule Dobro.Runtime.ActorRegistry do
  @moduledoc """
  Behaviour for looking up locally registered Dobro runtime actors.

  Configure via:

      config :dobro_runtime,
        actor_registry: {Dobro.Runtime.ActorRegistry.Local, []}
  """

  @type key :: term()

  @callback lookup(key()) :: {:ok, pid()} | :miss
  @callback via(key()) :: {:via, module(), term()}

  @doc "Resolves the configured actor registry module and options."
  @spec config() :: {module(), keyword()}
  def config do
    case Application.get_env(:dobro_runtime, :actor_registry, {Dobro.Runtime.ActorRegistry.Local, []}) do
      {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  @doc "Configured registry module."
  @spec module() :: module()
  def module, do: elem(config(), 0)

  @spec lookup(key()) :: {:ok, pid()} | :miss
  def lookup(key) do
    {mod, _opts} = config()
    mod.lookup(key)
  end

  @spec via(key()) :: {:via, module(), term()}
  def via(key) do
    {mod, _opts} = config()
    mod.via(key)
  end
end
