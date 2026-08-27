defmodule Dobro.Infra.Data.DomainEventOutboxSchema do
  @moduledoc """
  Transactional outbox rows for reliable domain event delivery.
  """

  use TypedEctoSchema

  @primary_key {:id, :binary_id, autogenerate: true}

  typed_schema "domain_event_outbox", prefix: "shared" do
    field :stream_name, :string
    field :event_payload, :map
    field :message_identity, :map
    field :processed_at, :naive_datetime_usec

    timestamps(updated_at: false, type: :naive_datetime_usec)
  end
end
