defmodule Dobro.App.DomainEventCodecTest do
  use ExUnit.Case, async: true

  alias Dobro.App.DomainEventCodec
  alias Dobro.Domain.Messages.MessageIdentity
  alias Dobro.TestSupport.SampleEvent

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
end
