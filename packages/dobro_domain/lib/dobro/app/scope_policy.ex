defmodule Dobro.App.ScopePolicy do
  @moduledoc """
  Checks that a request's scope is one a read repo serves: its declared
  `scopes:` and its tenant strategy.
  """

  alias Dobro.App.Auth.{GlobalContext, TenantContext}
  alias Dobro.Infra.Data.ReadRepo.{SchemaStrategy, TenantIdStrategy}

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @doc """
  Validates a resolved tenant against `repo`. `%GlobalContext{}` requires `:global`.
  `%TenantContext{}` requires `:tenant`. A schema repo rejects `%GlobalContext{}`.
  """
  def validate_context!(tenant, repo) do
    mode =
      case tenant do
        %GlobalContext{} -> :global
        %TenantContext{} -> :tenant
        _ -> :global
      end

    allowed_scopes = repo.__allowed_scopes__()

    unless mode in allowed_scopes do
      raise Error,
        message:
          "#{inspect(repo)} does not allow scope mode #{inspect(mode)} " <>
            "(allowed: #{inspect(allowed_scopes)})"
    end

    strategy = repo.strategy()

    cond do
      match?(%GlobalContext{}, tenant) and strategy == SchemaStrategy ->
        raise Error,
          message:
            "#{inspect(repo)} uses schema tenant strategy and requires a tenant context"

      strategy in [SchemaStrategy, TenantIdStrategy] and is_nil(tenant) ->
        raise Error,
          message:
            "#{inspect(repo)} requires a resolved tenant for strategy #{inspect(strategy)}"

      true ->
        :ok
    end
  end
end
