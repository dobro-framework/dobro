defmodule Dobro.Infra.Data.DomainEventRecordSchema do
  @moduledoc """
  Append-only domain event records for event-sourced persistence.
  """

  use TypedEctoSchema

  @primary_key {:id, :id, autogenerate: true}
  @schema_prefix "event_store"

  typed_schema "domain_events" do
    field :stream_name, :string
    field :event_number, :integer
    field :event_type, :string
    field :event_payload, :map
    field :message_identity, :map
    field :version, :integer

    timestamps(updated_at: false, type: :naive_datetime_usec)
  end
end
