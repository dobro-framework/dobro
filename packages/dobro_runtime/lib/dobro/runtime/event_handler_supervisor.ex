defmodule Dobro.Runtime.EventHandlerSupervisor do
  @moduledoc """
  Supervisor for the EventHandlerActor
  """
  use Supervisor

  alias Dobro.Ports.EventHandler
  alias Dobro.Runtime.DomainEventPoller

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children =
      EventHandler.all()
      |> Enum.flat_map(fn handler ->
        DomainEventPoller.streams(handler)
        |> Enum.map(fn stream ->
          Supervisor.child_spec(
            {DomainEventPoller, [handler: handler, stream: stream]},
            id: {DomainEventPoller, handler, stream}
          )
        end)
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
