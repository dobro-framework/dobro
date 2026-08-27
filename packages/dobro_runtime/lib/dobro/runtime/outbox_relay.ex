defmodule Dobro.Runtime.OutboxRelay do
  @moduledoc """
  Polls the domain event outbox and publishes staged events to PubSub.
  """

  use GenServer

  alias Dobro.Runtime.Command.EventDeliveryStrategy.Outbox

  @default_poll_interval_ms 1_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    schedule_poll(opts)
    {:ok, opts}
  end

  @impl GenServer
  def handle_info(:poll, opts) do
    Outbox.relay(Keyword.take(opts, [:batch_size]))
    schedule_poll(opts)
    {:noreply, opts}
  end

  defp schedule_poll(opts) do
    interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    Process.send_after(self(), :poll, interval)
  end
end
