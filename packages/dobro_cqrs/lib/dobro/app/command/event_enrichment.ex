defmodule Dobro.App.Command.EventEnrichment do
  @moduledoc """
  Enriches domain events during command commit.

  Adds command message identity and aggregate ids before events are stored or
  delivered.
  """

  alias Dobro.Domain.Messages.MessageIdentity
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  @doc "Enriches events with message identity and aggregate ids."
  @spec enrich([term()], term(), UnitOfWork.t()) :: [term()]
  def enrich(events, message_identity, unit_of_work) do
    Enum.map(events, fn event -> enrich_event(event, message_identity, unit_of_work) end)
  end

  defp enrich_event(%{} = event, message_identity, unit_of_work) do
    %{
      event
      | message_identity:
          MessageIdentity.corresponding_to(
            event.message_identity,
            message_identity
          )
    }
    |> enrich_event_payload(unit_of_work)
  end

  defp enrich_event_payload(%{payload: %{id: id}} = event, unit_of_work) when is_nil(id) do
    %{event | payload: %{event.payload | id: unit_of_work.aggregate.id}}
  end

  defp enrich_event_payload(event, _), do: event
end
