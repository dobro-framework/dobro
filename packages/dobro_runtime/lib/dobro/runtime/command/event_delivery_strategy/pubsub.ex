defmodule Dobro.Runtime.Command.EventDeliveryStrategy.PubSub do
  @moduledoc """
  Broadcasts domain events on aggregate PubSub streams after commit.
  """

  @behaviour Dobro.App.Command.EventDeliveryStrategy

  alias Phoenix.PubSub

  @impl true
  def stage(_events, _context, _opts), do: :ok

  @impl true
  def deliver(events, %{aggregate: aggregate}, _opts) do
    stream = stream_name(aggregate)

    Enum.each(events, fn event ->
      PubSub.broadcast(Dobro.Config.pubsub!(), stream, {:event, event})
    end)

    :ok
  end

  @impl true
  def transactional_stage?, do: false

  defp stream_name(%_{} = aggregate), do: stream_name(aggregate.__struct__)

  defp stream_name(aggregate_module) when is_atom(aggregate_module) do
    aggregate_module.__stream_name__()
  end
end
