defmodule Dobro.Runtime.EventHandlerActor do
  @moduledoc """
  Actor for an event handler - as a GenServer
  """
  use GenServer

  alias Phoenix.PubSub

  defmodule Config do
    @moduledoc """
    Config for the EventHandlerActor
    """
    use TypedStruct

    typedstruct do
      field :event_handler_module, module()
    end
  end

  defstruct [:config, :handler_state]

  def start_link(opts) do
    event_handler_module = Keyword.fetch!(opts, :event_handler_module)
    stream_name = event_handler_module.__stream_name__()
    name = actor_name(event_handler_module, stream_name)

    state = %__MODULE__{
      config: %{
        event_handler_module: event_handler_module
      },
      handler_state: nil
    }

    GenServer.start_link(__MODULE__, state, name: name)
  end

  @doc """
  Generates a unique name for the EventHandlerActor
  """
  def actor_name(event_handler_module, stream_name) do
    "event_handler_actor_#{event_handler_module}_#{stream_name}"
    |> String.to_atom()
  end

  @impl GenServer
  def init(%__MODULE__{} = state) do
    {:ok, state, {:continue, :subscribe_to_stream}}
  end

  @impl GenServer
  def handle_continue(:subscribe_to_stream, %__MODULE__{} = state) do
    # @todo: build an abstraction for subscribing to a stream
    case PubSub.subscribe(Dobro.Config.pubsub!(), stream_name(state)) do
      :ok ->
        {:noreply, state}

      {:error, error} ->
        IO.warn("Failed to subscribe to stream #{stream_name(state)}: #{inspect(error)}")
        {:stop, {:error, error}, state}
    end
  end

  defp stream_name(state) do
    state.config.event_handler_module.__stream_name__()
  end

  @impl GenServer
  def handle_info({:event, event}, %__MODULE__{} = state) do
    case state.config.event_handler_module.handle(event) do
      :ok ->
        {:noreply, state}

      {:ok, handler_state} ->
        {:noreply, %{state | handler_state: handler_state}}

      {:error, error} ->
        IO.warn("Failed to handle event #{inspect(event)}: #{inspect(error)}")
        {:stop, {:error, error}, state}
    end
  end

  def read_handler_state(event_handler_module) do
    actor_name = actor_name(event_handler_module, event_handler_module.__stream_name__())
    GenServer.call(actor_name, :read_handler_state)
  end

  @impl GenServer
  def handle_call(:read_handler_state, _from, state) do
    {:reply, state.handler_state, state}
  end

  @doc """
  Generates a via tuple for the EventHandlerActor
  """
  def via(event_handler_module, stream_name) do
    actor_name = actor_name(event_handler_module, stream_name)
    {:via, Registry, {Dobro.Runtime.Registry, actor_name}}
  end
end
