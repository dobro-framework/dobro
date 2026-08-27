defmodule Dobro.Runtime.EventHandlerSupervisor do
  @moduledoc """
  Supervisor for the EventHandlerActor
  """
  use Supervisor

  alias Dobro.Ports.EventHandler
  alias Dobro.Runtime.EventHandlerActor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children =
      EventHandler.all()
      |> Enum.map(fn event_handler_module ->
        Supervisor.child_spec(
          {
            EventHandlerActor,
            [
              event_handler_module: event_handler_module
            ]
          },
          id: "event_handler_actor_#{event_handler_module}"
        )
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
