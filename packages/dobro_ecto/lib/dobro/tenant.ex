defmodule Dobro.Tenant do
  @moduledoc """
  Tenant context normalization for multi-tenant runtime partitioning.

  Aggregate actors and event streams always key by immutable tenant `:id`.

  When a `Dobro.Tenant.Resolver` is configured, incomplete tenant contexts are
  enriched via `normalize/1`:

  - identifier only → resolve `:id`
  - id only → resolve `:identifier` (for schema-prefixed repos)
  - both present → no lookup
  """

  alias Dobro.App.Auth.TenantContext
  alias Dobro.Error

  @doc """
  Ensures a tenant context has both `:id` and `:identifier` when a resolver is configured.

  `nil` (global scope) is returned unchanged. Complete contexts are returned as-is.
  Incomplete contexts are enriched via the configured `Dobro.Tenant.Resolver`.
  """
  @spec normalize(TenantContext.t() | nil) :: {:ok, TenantContext.t() | nil} | {:error, term()}
  def normalize(nil), do: {:ok, nil}

  def normalize(%TenantContext{id: id, identifier: identifier} = tenant)
      when not is_nil(id) and is_binary(identifier) and identifier != "" do
    {:ok, tenant}
  end

  def normalize(%TenantContext{} = tenant) do
    case resolver() do
      nil ->
        case tenant do
          %TenantContext{id: id} when not is_nil(id) -> {:ok, tenant}
          _ -> {:error, Error.new(:tenant_id_required)}
        end

      module ->
        module.normalize(tenant) |> then(&ensure_id/1)
    end
  end

  @doc "Like `normalize/1`, but raises on failure."
  @spec normalize!(TenantContext.t() | nil) :: TenantContext.t() | nil
  def normalize!(tenant) do
    case normalize(tenant) do
      {:ok, normalized} ->
        normalized

      {:error, reason} ->
        raise ArgumentError, "Failed to normalize tenant: #{inspect(reason)}"
    end
  end

  @doc """
  Partition key for tenant-scoped runtime resources after normalization.

  Always keys by tenant `:id`. Returns `{:ok, key}` or `{:error, reason}`.
  """
  @spec partition_key(TenantContext.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def partition_key(tenant) do
    with {:ok, normalized} <- normalize(tenant) do
      {:ok, TenantContext.partition_key(normalized)}
    end
  end

  @doc "Like `partition_key/1`, but raises on normalization failure."
  @spec partition_key!(TenantContext.t() | nil) :: String.t()
  def partition_key!(tenant) do
    tenant
    |> normalize!()
    |> TenantContext.partition_key()
  end

  defp ensure_id({:ok, %TenantContext{id: id} = tenant}) when not is_nil(id), do: {:ok, tenant}
  defp ensure_id({:ok, _}), do: {:error, Error.new(:tenant_id_required)}
  defp ensure_id({:error, _} = error), do: error

  defp resolver, do: Dobro.Config.tenant_resolver()
end
