defmodule Dobro.Domain.SpecificationContext do
  @moduledoc """
  Context passed to domain specifications when validating a command operation.

  - `contract` — the domain operation contract built from the command payload
  - `identity` — aggregate identity from the command, when present
  - `tenant` — resolved tenant context for the command scope, when present
  """

  alias Dobro.App.Auth.TenantContext

  @type t :: %{
          contract: term(),
          identity: map() | nil,
          tenant: TenantContext.t() | nil
        }

  def new(contract, identity \\ nil, tenant \\ nil) do
    %{contract: contract, identity: identity, tenant: tenant}
  end
end
