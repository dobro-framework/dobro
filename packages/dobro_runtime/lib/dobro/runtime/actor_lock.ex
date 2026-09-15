defmodule Dobro.Runtime.ActorLock do
  @moduledoc """
  Behaviour for cluster-wide exclusive ownership of Dobro runtime actors.

  Configure via:

      config :dobro_runtime,
        actor_lock: {Dobro.Runtime.ActorLock.None, []}
        # or {Dobro.Runtime.ActorLock.Postgres, []}
  """

  @type key :: term()
  @type owner :: pid()
  @type locate :: {:ok, pid()} | {:ok, node(), pid()} | :unknown

  @callback try_acquire(key(), owner()) :: :ok | {:error, :locked} | {:error, term()}
  @callback release(key()) :: :ok
  @callback whereis(key()) :: locate()

  @doc "Resolves the configured actor lock module and options."
  @spec config() :: {module(), keyword()}
  def config do
    case Application.get_env(:dobro_runtime, :actor_lock, {Dobro.Runtime.ActorLock.None, []}) do
      {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  @doc "Configured lock module."
  @spec module() :: module()
  def module, do: elem(config(), 0)

  @doc "Attempts to acquire exclusive ownership of `key` for `owner`."
  @spec try_acquire(key(), owner()) :: :ok | {:error, :locked} | {:error, term()}
  def try_acquire(key, owner) when is_pid(owner) do
    {mod, _opts} = config()
    mod.try_acquire(key, owner)
  end

  @doc "Releases ownership of `key` if held."
  @spec release(key()) :: :ok
  def release(key) do
    {mod, _opts} = config()
    mod.release(key)
  end

  @doc "Looks up the current owner of `key`, if known."
  @spec whereis(key()) :: locate()
  def whereis(key) do
    {mod, _opts} = config()
    mod.whereis(key)
  end

  @doc "Child specs to start for the configured lock adapter (may be empty)."
  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    {mod, opts} = config()

    if function_exported?(mod, :child_specs, 1) do
      mod.child_specs(opts)
    else
      []
    end
  end
end
