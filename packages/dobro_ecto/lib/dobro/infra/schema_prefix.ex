defmodule Dobro.Infra.SchemaPrefix do
  @moduledoc """
  Resolves Ecto schema prefixes from tenant context via a configurable resolver.
  """

  alias Dobro.App.Auth.TenantContext

  @doc "Returns repo options with a schema prefix for the given tenant context."
  @spec repo_opts(map()) :: {:ok, keyword()} | {:error, term()}
  def repo_opts(%{tenant: %TenantContext{} = tenant_context}) do
    with {:ok, prefix} <- schema_prefix_for(tenant_context) do
      {:ok, [prefix: prefix]}
    end
  end

  @doc "Returns repo options with a schema prefix, raising on failure."
  @spec repo_opts!(map()) :: keyword()
  def repo_opts!(%{tenant: %TenantContext{} = tenant_context}) do
    [prefix: schema_prefix_for!(tenant_context)]
  end

  @doc "Resolves a schema prefix for the given tenant."
  @spec schema_prefix_for(TenantContext.t()) :: {:ok, String.t()} | {:error, term()}
  def schema_prefix_for(%TenantContext{} = tenant) do
    case resolver!() do
      nil -> {:error, :tenant_resolver_not_configured}
      module -> module.schema_prefix_for(tenant)
    end
  end

  @doc "Resolves a schema prefix for the given tenant, raising on failure."
  @spec schema_prefix_for!(TenantContext.t()) :: String.t()
  def schema_prefix_for!(%TenantContext{} = tenant) do
    case resolver!() do
      nil -> raise "tenant resolver not configured for schema prefix lookup"
      module -> module.schema_prefix_for!(tenant)
    end
  end

  defp resolver! do
    Dobro.Config.tenant_resolver()
  end
end
