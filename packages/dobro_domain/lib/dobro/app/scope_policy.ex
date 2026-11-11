defmodule Dobro.App.ScopePolicy do
  @moduledoc """
  Validates that a resolved `ScopeContext` is compatible with a read repo's strategy
  and declared allowed scopes.
  """

  alias Dobro.App.Auth.{GlobalContext, TenantContext}
  alias Dobro.App.Scope.ScopeContext
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

  def validate!(%ScopeContext{} = scope_context, repo) do
    effective_mode = effective_mode(scope_context)
    allowed_scopes = repo.__allowed_scopes__()

    unless effective_mode in allowed_scopes do
      raise Error,
        message:
          "#{inspect(repo)} does not allow scope mode #{inspect(effective_mode)} " <>
            "(allowed: #{inspect(allowed_scopes)})"
    end

    strategy = repo.strategy()

    cond do
      effective_mode == :global and strategy == SchemaStrategy ->
        raise Error,
          message:
            "#{inspect(repo)} uses schema tenant strategy but was invoked from global scope"

      strategy in [SchemaStrategy, TenantIdStrategy] and is_nil(scope_context.tenant) ->
        raise Error,
          message:
            "#{inspect(repo)} requires a resolved tenant for strategy #{inspect(strategy)}"

      true ->
        :ok
    end
  end

  defp effective_mode(%ScopeContext{mode: :dynamic, tenant: nil}), do: :global
  defp effective_mode(%ScopeContext{mode: :dynamic, tenant: _}), do: :tenant
  defp effective_mode(%ScopeContext{mode: mode}), do: mode

  @doc """
  Validates at compile time that a query's scope is compatible with a read repo.
  """
  def validate_wiring!(query_module, repo_module, env \\ nil) do
    with {:module, _} <- Code.ensure_compiled(query_module),
         {:module, _} <- Code.ensure_compiled(repo_module),
         true <- function_exported?(repo_module, :__allowed_scopes__, 0) do
      do_validate_wiring!(query_module, repo_module, env)
    else
      _ -> :ok
    end
  end

  defp do_validate_wiring!(query_module, repo_module, env) do
    query_scope = if function_exported?(query_module, :__scope__, 0), do: query_module.__scope__()

    if is_nil(query_scope) do
      :ok
    else
      validate_scope_modes!(query_scope, query_module, repo_module, env)
    end
  end

  defp validate_scope_modes!(query_scope, query_module, repo_module, env) do
    allowed_scopes = repo_module.__allowed_scopes__()

    case required_modes(query_scope) do
      modes when is_list(modes) ->
        if Enum.any?(modes, &(&1 in allowed_scopes)) do
          :ok
        else
          raise_compile_error!(
            """
            #{inspect(query_module)} scope #{inspect(query_scope)} is incompatible with \
            #{inspect(repo_module)} (allowed scopes: #{inspect(allowed_scopes)})
            """,
            env
          )
        end

      :ok ->
        :ok
    end
  end

  defp required_modes({:global, nil}), do: [:global]
  defp required_modes({:tenant, :context}), do: [:tenant]
  defp required_modes({:tenant, _tenant_id}), do: [:tenant]
  defp required_modes({:dynamic, nil}), do: :ok

  defp required_modes(scope),
    do: raise_compile_error!("Unsupported scope for wiring validation: #{inspect(scope)}", nil)

  defp raise_compile_error!(message, nil), do: raise(message)

  defp raise_compile_error!(message, %Macro.Env{} = env),
    do: raise(CompileError, description: message, file: env.file, line: env.line)
end
