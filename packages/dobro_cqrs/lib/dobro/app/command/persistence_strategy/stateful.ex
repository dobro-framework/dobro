defmodule Dobro.App.Command.PersistenceStrategy.Stateful do
  @moduledoc """
  Persists aggregate snapshots through WriteRepo ports.
  """

  @behaviour Dobro.App.Command.PersistenceStrategy

  alias Dobro.App.Command.EventEnrichment
  alias Dobro.Infra.Data.WriteRepo.Persist

  @impl true
  def persist(unit_of_work, events, tenant, message_identity, _opts) do
    with {:ok, unit_of_work} <- Persist.save(unit_of_work, events, tenant) do
      enriched = EventEnrichment.enrich(events, message_identity, unit_of_work)
      {:ok, unit_of_work, enriched}
    end
  end

  @impl true
  def transactional_persist?(unit_of_work, events, _tenant, _opts) do
    Persist.transactional?(unit_of_work, events)
  end
end
