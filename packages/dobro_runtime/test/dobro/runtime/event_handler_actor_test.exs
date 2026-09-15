defmodule Dobro.Runtime.EventHandlerActorTest do
  use ExUnit.Case, async: false

  alias Dobro.Runtime.ActorLock.Memory
  alias Dobro.Runtime.EventHandlerActor

  defmodule CountingHandler do
    use Dobro.Spec.Adapter, port: Dobro.Ports.EventHandler

    @stream "event_handler_actor_test_stream"

    def __stream_name__, do: @stream
    def __consumer_mode__, do: :singleton

    def handle({:event_payload, parent}) do
      send(parent, {:handled, self()})
      :ok
    end

    def handle(_), do: :ok
  end

  defmodule FanoutHandler do
    use Dobro.Spec.Adapter, port: Dobro.Ports.EventHandler

    @stream "event_handler_fanout_test_stream"

    def __stream_name__, do: @stream
    def __consumer_mode__, do: :every_node

    def handle({:event_payload, parent}) do
      send(parent, {:handled, Node.self(), self()})
      :ok
    end

    def handle(_), do: :ok
  end

  setup do
    previous_lock = Application.get_env(:dobro_runtime, :actor_lock)
    previous_pubsub = Application.get_env(:dobro_runtime, :pubsub)

    Application.put_env(:dobro_runtime, :actor_lock, {Memory, []})
    Application.put_env(:dobro_runtime, :pubsub, __MODULE__.PubSub)

    start_supervised!({Registry, keys: :unique, name: Dobro.Runtime.Registry})
    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})
    start_supervised!(Memory)

    on_exit(fn ->
      restore(:dobro_runtime, :actor_lock, previous_lock)
      restore(:dobro_runtime, :pubsub, previous_pubsub)
    end)

    :ok
  end

  test "singleton mode only one subscriber handles events" do
    {:ok, pid1} =
      start_supervised(
        {EventHandlerActor, [event_handler_module: CountingHandler]},
        id: :handler_1
      )

    Process.sleep(20)

    parent = self()

    standby =
      spawn(fn ->
        key = EventHandlerActor.actor_key(CountingHandler)

        case Memory.try_acquire(key, self()) do
          :ok -> send(parent, :standby_got_lock)
          {:error, :locked} -> send(parent, :standby_locked)
        end

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :standby_locked
    assert Process.alive?(pid1)

    Phoenix.PubSub.broadcast(
      __MODULE__.PubSub,
      CountingHandler.__stream_name__(),
      {:event, {:event_payload, self()}}
    )

    assert_receive {:handled, ^pid1}
    refute_receive {:handled, _}, 100

    send(standby, :stop)
  end

  test "every_node mode subscribes without requiring exclusive lock win for others" do
    {:ok, _pid} =
      start_supervised({EventHandlerActor, [event_handler_module: FanoutHandler]}, id: :fanout_1)

    # Allow subscribe continue to run
    Process.sleep(20)

    Phoenix.PubSub.broadcast(
      __MODULE__.PubSub,
      FanoutHandler.__stream_name__(),
      {:event, {:event_payload, self()}}
    )

    assert_receive {:handled, _, _}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
