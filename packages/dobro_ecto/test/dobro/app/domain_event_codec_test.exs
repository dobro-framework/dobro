defmodule Dobro.App.DomainEventCodecTest do
  use ExUnit.Case, async: true

  alias Dobro.App.DomainEventCodec
  alias Dobro.Domain.Messages.MessageIdentity
  alias Dobro.TestSupport.SampleContact
  alias Dobro.TestSupport.SampleEvent
  alias Dobro.TestSupport.SampleTypedEvents.ContactUpdated

  test "round-trips a domain event through encode/decode" do
    event = %SampleEvent{
      payload: %{name: "Office Supplies"},
      message_identity: MessageIdentity.new!(%{id: "msg-1"}),
      version: 1
    }

    encoded = DomainEventCodec.encode(event)
    decoded = DomainEventCodec.decode(encoded)

    assert decoded.__struct__ == SampleEvent
    assert decoded.payload.name == "Office Supplies"
    assert decoded.message_identity.id == "msg-1"
    assert decoded.version == 1
  end

  test "encode deep-flattens nested value objects in the payload" do
    contact = SampleContact.load!(%{person_id: 7, relationship: "spouse"})

    event = %SampleEvent{
      payload: %{name: "Nested", contact: contact, contacts: [contact]},
      message_identity: MessageIdentity.new!(%{id: "msg-2"}),
      version: 1
    }

    encoded = DomainEventCodec.encode(event)

    assert encoded["payload"] == %{
             name: "Nested",
             contact: %{person_id: 7, relationship: "spouse"},
             contacts: [%{person_id: 7, relationship: "spouse"}]
           }

    refute match?(%{__struct__: _}, encoded["payload"].contact)
  end

  test "decode rehydrates nested value objects from a typed event payload" do
    {:ok, event} =
      ContactUpdated.new(%{
        payload: %{
          name: "Alex",
          contact: %{person_id: 3, relationship: "nok"},
          contacts: [%{person_id: 4, relationship: "friend"}]
        }
      })

    encoded = DomainEventCodec.encode(event)
    # Simulate JSONB string-key round-trip
    encoded =
      encoded
      |> Jason.encode!()
      |> Jason.decode!()

    decoded = DomainEventCodec.decode(encoded)

    assert %ContactUpdated{} = decoded
    assert %ContactUpdated.Payload{} = decoded.payload
    assert decoded.payload.name == "Alex"
    assert %SampleContact{person_id: 3, relationship: "nok"} = decoded.payload.contact

    assert [%SampleContact{person_id: 4, relationship: "friend"}] =
             decoded.payload.contacts
  end

  test "decode keeps plain maps when the event has no payload schema" do
    encoded = %{
      "event_type" => "Elixir.Dobro.TestSupport.SampleEvent",
      "payload" => %{"name" => "Legacy"},
      "message_identity" => %{"id" => "msg-3"},
      "version" => 2
    }

    decoded = DomainEventCodec.decode(encoded)

    assert decoded.payload == %{name: "Legacy"}
    assert decoded.message_identity.id == "msg-3"
  end
end
