defmodule Dobro.App.Command.EventEnrichmentTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.Command.EventEnrichment
  alias Dobro.Domain.Messages.MessageIdentity
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  defmodule Aggregate do
    defstruct [:id, :name]
  end

  defmodule Created do
    defstruct [:payload, :message_identity]
  end

  defmodule CreatedPayload do
    defstruct [:id, :name, :tenant_id]
  end

  defmodule NoTenantPayload do
    defstruct [:id, :name]
  end

  defp message_identity, do: MessageIdentity.new!(%{id: "command-id"})
  defp event_identity, do: MessageIdentity.new!(%{id: "event-id"})

  defp unit_of_work do
    UnitOfWork.new(%{aggregate: %Aggregate{id: 42, name: "Acme"}, schema: nil})
  end

  test "fills nil payload ids from the persisted aggregate" do
    event = %Created{
      payload: %{id: nil, name: "Acme"},
      message_identity: event_identity()
    }

    assert [%Created{payload: %{id: 42}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work())
  end

  test "leaves payload ids that are already set" do
    event = %Created{
      payload: %{id: 7, name: "Acme"},
      message_identity: event_identity()
    }

    assert [%Created{payload: %{id: 7}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work())
  end

  test "stamps tenant_id from tenant context onto map payloads" do
    event = %Created{
      payload: %{id: nil, name: "Acme"},
      message_identity: event_identity()
    }

    tenant = TenantContext.new(%{id: 9, identifier: "acme"})

    assert [%Created{payload: %{id: 42, tenant_id: 9}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work(), tenant)
  end

  test "stamps tenant_id onto struct payloads that declare the field" do
    event = %Created{
      payload: %CreatedPayload{id: nil, name: "Acme", tenant_id: nil},
      message_identity: event_identity()
    }

    tenant = TenantContext.new(%{id: 9, identifier: "acme"})

    assert [%Created{payload: %CreatedPayload{id: 42, tenant_id: 9}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work(), tenant)
  end

  test "does not add tenant_id to struct payloads without the field" do
    event = %Created{
      payload: %NoTenantPayload{id: nil, name: "Acme"},
      message_identity: event_identity()
    }

    tenant = TenantContext.new(%{id: 9, identifier: "acme"})

    assert [%Created{payload: %NoTenantPayload{id: 42} = payload}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work(), tenant)

    refute Map.has_key?(payload, :tenant_id)
  end

  test "leaves an already-set tenant_id alone" do
    event = %Created{
      payload: %CreatedPayload{id: 7, name: "Acme", tenant_id: 3},
      message_identity: event_identity()
    }

    tenant = TenantContext.new(%{id: 9, identifier: "acme"})

    assert [%Created{payload: %CreatedPayload{tenant_id: 3}}] =
             EventEnrichment.enrich([event], message_identity(), unit_of_work(), tenant)
  end
end
