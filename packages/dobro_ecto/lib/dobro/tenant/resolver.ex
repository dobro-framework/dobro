defmodule Dobro.Tenant.Resolver do
  @moduledoc """
  Behaviour for resolving and normalizing tenant context for multi-tenancy.

  Implement in your host application when using schema-per-tenant strategy.
  """

  alias Dobro.App.Auth.TenantContext

  @doc """
  Resolves a schema prefix (Postgres schema name) for the given tenant.
  """
  @callback schema_prefix_for(tenant :: TenantContext.t()) ::
              {:ok, String.t()} | {:error, term()}

  @callback schema_prefix_for!(tenant :: TenantContext.t()) :: String.t()

  @doc """
  Returns a fully populated tenant context.

  Implementations should resolve whichever of `:id` or `:identifier` is missing.
  Contexts that already include both are returned unchanged.
  """
  @callback normalize(tenant :: TenantContext.t()) ::
              {:ok, TenantContext.t()} | {:error, term()}
end
