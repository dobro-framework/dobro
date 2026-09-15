defmodule Dobro.Runtime.ActorLock.LeaseSchema do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  @schema_prefix "shared"
  schema "actor_leases" do
    field :lock_key, :string, primary_key: true
    field :node, :string
    field :owner, :string

    timestamps(type: :utc_datetime_usec)
  end
end
