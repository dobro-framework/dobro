defmodule Dobro.Infra.Data.IntegrationSubscriptionSchema do
  @moduledoc """
  Cursor for one handler on one integration pattern or one domain stream.

  `log` is `"integration"` or `"domain"`. Integration cursors use `last_position`.
  Domain cursors use `last_inserted_at` and `last_event_id`.
  """

  use TypedEctoSchema

  @schema_prefix "shared"
  @primary_key false

  typed_schema "integration_subscriptions" do
    field :handler_module, :string, primary_key: true
    field :log, :string, primary_key: true
    field :pattern, :string, primary_key: true
    field :last_position, :integer
    field :last_inserted_at, :naive_datetime_usec
    field :last_event_id, :integer
    field :failure_count, :integer, default: 0
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end
end
