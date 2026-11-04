defmodule Dobro.App.Command.EventEnrichment do
  @moduledoc """
  Enriches domain events during command commit.

  Adds command message identity, aggregate identity fields, and tenant_id
  (from the commit tenant context) before events are stored or delivered.

  `tenant_id` is only written when the payload declares the field and it is
  nil/missing — aggregates stay tenant-free; events carry tenant for consumers
  that cannot look up by id alone (tenant-schema persistence).
  """

  alias Dobro.App.Auth.TenantContext
  alias Dobro.Domain.Messages.MessageIdentity
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  @doc "Enriches events with message identity, aggregate identity, and tenant_id."
  @spec enrich([term()], term(), UnitOfWork.t(), TenantContext.t() | nil) :: [term()]
  def enrich(events, message_identity, unit_of_work, tenant \\ nil) do
    Enum.map(events, fn event ->
      enrich_event(event, message_identity, unit_of_work, tenant)
    end)
  end

  @doc """
  Merges an identity map onto an aggregate struct (immutable identity fields).

  Used after optional-load creates so natural-key identity from the command is
  present before persist / event enrichment.
  """
  @spec stamp_identity(term(), map() | nil) :: term()
  def stamp_identity(aggregate, identity) when is_map(identity) and map_size(identity) > 0 do
    Enum.reduce(identity, aggregate, fn {key, value}, acc ->
      key = if is_atom(key), do: key, else: String.to_existing_atom(to_string(key))

      if is_nil(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  rescue
    ArgumentError ->
      aggregate
  end

  def stamp_identity(aggregate, _), do: aggregate

  defp enrich_event(%{} = event, message_identity, unit_of_work, tenant) do
    %{
      event
      | message_identity:
          MessageIdentity.corresponding_to(
            event.message_identity,
            message_identity
          )
    }
    |> enrich_event_payload(unit_of_work)
    |> enrich_event_tenant(tenant)
  end

  defp enrich_event_payload(%{payload: payload} = event, %{aggregate: aggregate})
       when is_map(payload) and not is_nil(aggregate) do
    payload =
      Enum.reduce(identity_attrs(aggregate), payload, fn {field, value}, acc ->
        put_if_blank(acc, field, value)
      end)

    %{event | payload: payload}
  end

  defp enrich_event_payload(event, _), do: event

  defp enrich_event_tenant(%{payload: payload} = event, %TenantContext{id: tenant_id})
       when is_map(payload) and not is_nil(tenant_id) do
    %{event | payload: put_if_blank(payload, :tenant_id, tenant_id)}
  end

  defp enrich_event_tenant(event, _), do: event

  defp put_if_blank(payload, _field, nil), do: payload

  defp put_if_blank(%{__struct__: _} = payload, field, value) do
    if Map.has_key?(payload, field) and is_nil(Map.get(payload, field)) do
      Map.put(payload, field, value)
    else
      payload
    end
  end

  defp put_if_blank(payload, field, value) when is_map(payload) do
    case Map.fetch(payload, field) do
      :error -> Map.put(payload, field, value)
      {:ok, nil} -> Map.put(payload, field, value)
      {:ok, _} -> payload
    end
  end


  defp identity_attrs(%{__struct__: mod} = aggregate) do
    fields =
      if function_exported?(mod, :__identity_fields__, 0) do
        mod.__identity_fields__()
      else
        [:id]
      end

    Enum.map(fields, fn field -> {field, Map.get(aggregate, field)} end)
  end

  defp identity_attrs(_), do: []
end
