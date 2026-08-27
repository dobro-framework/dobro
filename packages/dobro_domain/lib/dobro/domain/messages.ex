defmodule Dobro.Domain.Messages do
  @moduledoc """
  Domain message contracts such as `MessageIdentity`.
  """
  use Dobro.Contract

  alias Dobro.Domain.Id

  defcontract MessageIdentity do
    field :id, :string, required: true
    field :correlation_id, :string
    field :causation_id, :string

    @doc """
    Creates a new message identity for a reply.
    """
    def corresponding_to(%MessageIdentity{} = message_identity) do
      MessageIdentity.new!(%{
        id: Id.generate(),
        correlation_id: message_identity.correlation_id,
        causation_id: message_identity.id
      })
    end

    def corresponding_to(%MessageIdentity{} = new_identity, %MessageIdentity{} = message_identity) do
      MessageIdentity.new!(%{
        id: new_identity.id,
        correlation_id: message_identity.correlation_id,
        causation_id: message_identity.id
      })
    end
  end
end
