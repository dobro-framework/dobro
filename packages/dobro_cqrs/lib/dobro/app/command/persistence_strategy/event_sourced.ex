defmodule Dobro.App.Command.PersistenceStrategy.EventSourced do
  @moduledoc """
  Persists domain events by appending to the event store.

  Aggregate state is held in memory during command execution and can be rebuilt
  by replaying the stream through `Dobro.App.EventStore.replay/2`.
  """

  @behaviour Dobro.App.Command.PersistenceStrategy

  alias Dobro.App.Command.EventEnrichment
  alias Dobro.App.EventStore

  @impl true
  def persist(unit_of_work, events, tenant, message_identity, _opts) do
    enriched = EventEnrichment.enrich(events, message_identity, unit_of_work)

    stream_name =
      EventStore.stream_id(
        unit_of_work.aggregate.__struct__,
        tenant,
        stream_identity(unit_of_work.aggregate)
      )

    case EventStore.append(stream_name, enriched) do
      :ok -> {:ok, unit_of_work, enriched}
      error -> error
    end
  end

  @impl true
  def transactional_persist?(_unit_of_work, _events, _tenant, _opts), do: true

  defp stream_identity(%{id: id}) when not is_nil(id), do: %{id: id}
  defp stream_identity(_), do: nil
end
