defmodule Dobro.Infra.Data.IntegrationEventOutboxSchema do
  @moduledoc """
  Public integration events staged in the caller's transaction.

  `position` is the global order. `routing_key` is `{topic}.{event_name}`.
  `partition_key` is the aggregate id and becomes the broker record key.
  """

  use TypedEctoSchema

  @schema_prefix "shared"
  @primary_key false

  typed_schema "integration_event_outbox", prefix: "shared" do
    field :position, :integer, primary_key: true, read_after_writes: true
    field :id, :binary_id
    field :topic, :string
    field :event_name, :string
    field :routing_key, :string
    field :payload, :map
    field :causation_id, :binary_id
    field :partition_key, :string
    field :subject_type, :string
    field :subject_id, :string
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
