defmodule Dobro.App.Command.EventEnrichmentTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Command.EventEnrichment
  alias Dobro.Domain.Messages.MessageIdentity
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  defmodule Aggregate do
    defstruct [:id, :name]
  end

  defmodule Created do
    defstruct [:payload, :message_identity]
  end

  test "fills nil payload ids from the persisted aggregate" do
    message_identity = MessageIdentity.new!(%{id: "command-id"})
    event_identity = MessageIdentity.new!(%{id: "event-id"})

    event = %Created{
      payload: %{id: nil, name: "Acme"},
      message_identity: event_identity
    }

    unit_of_work =
      UnitOfWork.new(%{aggregate: %Aggregate{id: 42, name: "Acme"}, schema: nil})

    assert [%Created{payload: %{id: 42}}] =
             EventEnrichment.enrich([event], message_identity, unit_of_work)
  end

  test "leaves payload ids that are already set" do
    message_identity = MessageIdentity.new!(%{id: "command-id"})

    event = %Created{
      payload: %{id: 7, name: "Acme"},
      message_identity: MessageIdentity.new!(%{id: "event-id"})
    }

    unit_of_work =
      UnitOfWork.new(%{aggregate: %Aggregate{id: 42, name: "Acme"}, schema: nil})

    assert [%Created{payload: %{id: 7}}] =
             EventEnrichment.enrich([event], message_identity, unit_of_work)
  end
end
