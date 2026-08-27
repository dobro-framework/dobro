defmodule Dobro.Infra.Data.RepoContext do
  @moduledoc """
  Builds read and write repository contexts from tenant scope.
  """

  alias Dobro.App.Auth.TenantContext
  alias Dobro.Infra.Data.ReadRepo
  alias Dobro.Infra.Data.WriteRepo

  @spec for_tenant(TenantContext.t() | nil, :read | :write) :: map()
  def for_tenant(%TenantContext{} = tenant, :read), do: ReadRepo.Context.new(tenant: tenant)
  def for_tenant(%TenantContext{} = tenant, :write), do: WriteRepo.Context.new(tenant: tenant)
  def for_tenant(nil, :read), do: ReadRepo.Context.new(tenant: nil)
  def for_tenant(nil, :write), do: WriteRepo.Context.new(tenant: nil)
end
