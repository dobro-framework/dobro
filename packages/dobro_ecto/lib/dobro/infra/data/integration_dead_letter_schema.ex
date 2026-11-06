defmodule Dobro.Infra.Data.IntegrationDeadLetterSchema do
  @moduledoc """
  An event a handler failed repeatedly. The cursor moves past it.
  """

  use TypedEctoSchema

  @schema_prefix "shared"
  @primary_key {:id, :binary_id, autogenerate: true}

  typed_schema "integration_dead_letters" do
    field :handler_module, :string
    field :pattern, :string
    field :log, :string
    field :event_id, :binary_id
    field :payload, :map
    field :last_error, :string

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
