defmodule Dobro.Infra.Data.Query.StrategyOpts do
  @moduledoc false

  alias Dobro.App.Auth.{GlobalContext, TenantContext}
  alias Dobro.Infra.Data.Query.Spec
  alias Dobro.Infra.Data.ReadRepo.Context
  alias Dobro.Query.Tenant

  # Who owns a repo's rows when it does not say: a tenant, or no one (global).
  @default_owners [:tenant, :global]

  @doc """
  Tenant-filter options for running `spec` in `context`.

  The repo (`query_defaults: [owners: ...]`) or query (`owners:`) declares who
  can own its rows. A lookup reads the request tenant's rows and, when rows can
  be global, global ones; a global request reads every row. A list or facet
  returns the `owner` the request asks for (`requested`, relative to the
  request: `:tenant` is the request tenant's rows, or every tenant's when
  working globally), by default the tenant's and global rows inside a tenant,
  and global rows only when working globally.
  """
  @spec build(module(), Context.t() | nil, Spec.t(), [atom() | String.t()] | nil) :: keyword()
  def build(repo_module, context, %Spec{} = spec, requested \\ nil) do
    base =
      if tenant_context_mode?(repo_module) and match?(%Context{}, context) do
        [context: context]
      else
        []
      end

    available = spec.owners || query_default(repo_module, :owners) || @default_owners

    base
    |> Keyword.put(:include_global, :global in available)
    |> put_owner(spec.type, available, Tenant.normalize_owner(requested), tenant_of(context))
  end

  defp put_owner(opts, type, available, requested, tenant) when type in [:list, :facet] do
    case owner(tenant, requested, available) do
      nil -> opts
      owner -> Keyword.put(opts, :owner, owner)
    end
  end

  defp put_owner(opts, _type, _available, _requested, _tenant), do: opts

  defp owner(%TenantContext{}, requested, available),
    do: Enum.filter(requested || available, &(&1 in available))

  defp owner(%GlobalContext{}, requested, available),
    do: Enum.filter(requested || [:global], &(&1 in available))

  defp owner(_tenant, _requested, _available), do: nil

  defp tenant_of(%Context{tenant: tenant}), do: tenant
  defp tenant_of(_context), do: nil

  defp query_default(repo_module, key) do
    if function_exported?(repo_module, :__query_defaults__, 0) do
      repo_module.__query_defaults__()
      |> Keyword.get(key)
    end
  end

  defp tenant_context_mode?(repo_module) do
    function_exported?(repo_module, :context_mode, 0) &&
      repo_module.context_mode() == :tenant
  end
end
