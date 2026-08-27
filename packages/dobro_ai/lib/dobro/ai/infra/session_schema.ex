defmodule Dobro.AI.Infra.SessionSchema do
  @moduledoc """
  Persistent AI conversation session.
  """

  use TypedEctoSchema
  import Ecto.Changeset

  @schema_prefix "shared"
  @primary_key {:id, :id, autogenerate: true}
  @timestamps_opts [inserted_at: :created_at, updated_at: :updated_at]
  typed_schema "ai_sessions" do
    field(:user_id, :integer)
    field(:tenant_id, :integer)
    field(:context_type, :string)
    field(:context_key, :string)
    field(:messages, :map, default: %{})
    field(:status, :string, default: "active")
    field(:metadata, :map)
    timestamps()
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, [:user_id, :tenant_id, :context_type, :context_key, :messages, :status, :metadata])
    |> validate_required([:user_id, :context_type, :context_key, :messages, :status])
  end
end
