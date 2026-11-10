defmodule Dobro.Domain.SpecificationContext do
  @moduledoc """
  Context passed to domain specifications when validating a command operation.

  - `contract` — the domain operation contract built from the command payload
  - `identity` — aggregate identity from the command, when present
  - `tenant` — resolved tenant context for the command scope, when present
  - `auth_context` — the caller's auth, so a specification can read other
    data with the same authorization as the command
  """

  alias Dobro.App.Auth.{AuthContext, TenantContext}

  @type t :: %{
          contract: term(),
          identity: map() | nil,
          tenant: TenantContext.t() | nil,
          auth_context: AuthContext.t() | nil
        }

  def new(contract, identity \\ nil, tenant \\ nil, auth_context \\ nil) do
    %{contract: contract, identity: identity, tenant: tenant, auth_context: auth_context}
  end
end
