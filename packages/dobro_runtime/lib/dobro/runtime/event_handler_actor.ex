defmodule Dobro.Runtime.EventHandlerActor do
  @moduledoc """
  PubSub subscriber GenServer for a registered event handler or projector.

  With `consumer_mode: :singleton` (default), acquires an `ActorLock` and only
  the lock holder subscribes. Other nodes keep a standby that retries acquisition.
  With `consumer_mode: :every_node`, every node subscribes (explicit fan-out).
  """
  use GenServer

  alias Dobro.Runtime.ActorLock
  alias Dobro.Runtime.ActorRegistry
  alias Phoenix.PubSub

  require Logger

  @lock_released Dobro.Runtime.ActorLock.Postgres.lock_released_message()
  @standby_retry_ms 1_000

  defstruct [
    :event_handler_module,
    :actor_key,
    :consumer_mode,
    :handler_state,
    subscribed?: false,
    holds_lock?: false
  ]

  def start_link(opts) do
    event_handler_module = Keyword.fetch!(opts, :event_handler_module)
    actor_key = actor_key(event_handler_module)
    consumer_mode = consumer_mode(event_handler_module)

    state = %__MODULE__{
      event_handler_module: event_handler_module,
      actor_key: actor_key,
      consumer_mode: consumer_mode,
      handler_state: nil
    }

    GenServer.start_link(__MODULE__, state, name: ActorRegistry.via(actor_key))
  end

  def actor_key(event_handler_module) do
    {:event_handler, event_handler_module, event_handler_module.__stream_name__()}
  end

  @doc false
  def actor_name(event_handler_module, stream_name) do
    {:event_handler, event_handler_module, stream_name}
  end

  def via(event_handler_module, stream_name) do
    ActorRegistry.via({:event_handler, event_handler_module, stream_name})
  end

  def read_handler_state(event_handler_module) do
    GenServer.call(ActorRegistry.via(actor_key(event_handler_module)), :read_handler_state)
  end

  @impl GenServer
  def init(%__MODULE__{consumer_mode: :every_node} = state) do
    Process.flag(:trap_exit, true)
    {:ok, state, {:continue, :subscribe}}
  end

  def init(%__MODULE__{} = state) do
    Process.flag(:trap_exit, true)

    case ActorLock.try_acquire(state.actor_key, self()) do
      :ok ->
        {:ok, %{state | holds_lock?: true}, {:continue, :subscribe}}

      {:error, :locked} ->
        Process.send_after(self(), :retry_lock, @standby_retry_ms)
        {:ok, state}

      {:error, reason} ->
        Logger.warning("event handler lock error: #{inspect(reason)}")
        Process.send_after(self(), :retry_lock, @standby_retry_ms)
        {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:subscribe, state) do
    case subscribe(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl GenServer
  def handle_info(:retry_lock, %{holds_lock?: true} = state) do
    {:noreply, state}
  end

  def handle_info(:retry_lock, state) do
    case ActorLock.try_acquire(state.actor_key, self()) do
      :ok ->
        state = %{state | holds_lock?: true}

        case subscribe(state) do
          {:ok, state} -> {:noreply, state}
          {:error, reason} -> {:stop, reason, state}
        end

      {:error, :locked} ->
        Process.send_after(self(), :retry_lock, @standby_retry_ms)
        {:noreply, state}

      {:error, _reason} ->
        Process.send_after(self(), :retry_lock, @standby_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info({@lock_released, key, _reason}, %{actor_key: key} = state) do
    state = maybe_unsubscribe(%{state | holds_lock?: false, subscribed?: false})
    Process.send_after(self(), :retry_lock, @standby_retry_ms)
    {:noreply, state}
  end

  def handle_info({@lock_released, _key, _reason}, state), do: {:noreply, state}

  def handle_info({:event, event}, %{subscribed?: true} = state) do
    case state.event_handler_module.handle(event) do
      :ok ->
        {:noreply, state}

      {:ok, handler_state} ->
        {:noreply, %{state | handler_state: handler_state}}

      {:error, error} ->
        Logger.warning("Failed to handle event #{inspect(event)}: #{inspect(error)}")
        {:stop, {:error, error}, state}
    end
  end

  def handle_info({:event, _event}, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:read_handler_state, _from, state) do
    {:reply, state.handler_state, state}
  end

  @impl GenServer
  def terminate(_reason, %{holds_lock?: true, actor_key: key} = state) do
    _ = maybe_unsubscribe(state)
    ActorLock.release(key)
    :ok
  end

  def terminate(_reason, state) do
    _ = maybe_unsubscribe(state)
    :ok
  end

  defp subscribe(state) do
    case PubSub.subscribe(Dobro.Config.pubsub!(), stream_name(state)) do
      :ok ->
        {:ok, %{state | subscribed?: true}}

      {:error, error} ->
        Logger.warning("Failed to subscribe to stream #{stream_name(state)}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp maybe_unsubscribe(%{subscribed?: true} = state) do
    _ = PubSub.unsubscribe(Dobro.Config.pubsub!(), stream_name(state))
    %{state | subscribed?: false}
  end

  defp maybe_unsubscribe(state), do: state

  defp stream_name(state), do: state.event_handler_module.__stream_name__()

  defp consumer_mode(module) do
    cond do
      function_exported?(module, :__consumer_mode__, 0) ->
        module.__consumer_mode__()

      true ->
        Application.get_env(:dobro_runtime, :event_consumer_mode, :singleton)
    end
  end
end
