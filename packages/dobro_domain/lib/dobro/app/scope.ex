defmodule Dobro.App.Scope do
  @moduledoc """
  Resolves query and command scope into a `ScopeContext` for handlers and repos.

  Scope is declared on each query/command module (`scope :global`, `scope :tenant,
  from: :context`, etc.) and validated against the `ExecutionContext` at runtime.
  """

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.ExecutionContext

  defmodule ScopeContext do
    @moduledoc """
    Resolved scope for a query or command execution.

    For `:global` scope, `tenant` is always `nil` and an optional `tenant_id` on the
    payload is an ordinary filter field. For `:tenant` scope, `tenant` is resolved
    from the execution context or command payload.
    """
    use TypedStruct

    alias Dobro.App.Auth.TenantContext

    typedstruct do
      field :mode, :global | :tenant | :dynamic
      field :scope, term()
      field :tenant, TenantContext.t(), default: nil
    end

    def new(attrs), do: struct(__MODULE__, attrs)
  end

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  @type scope ::
          {:global, nil}
          | {:dynamic, nil}
          | {:tenant, :context}
          | {:tenant, pos_integer()}
          | {:tenant, String.t()}
          | {:tenant, {:identifier, String.t()}}
          | term()

  @doc """
  Resolves `scope` against `execution_context`, returning a `ScopeContext` or error tuple.
  """
  @spec setup(scope(), ExecutionContext.t()) :: {:ok, ScopeContext.t()} | {:error, String.t()}
  def setup(scope, execution_context \\ %ExecutionContext{})

  def setup({:tenant, :context}, %ExecutionContext{} = execution_context) do
    if is_nil(execution_context.tenant) do
      {:error, "Tenant context is required"}
    else
      {:ok,
       ScopeContext.new(
         mode: :tenant,
         scope: {:tenant, :context},
         tenant: execution_context.tenant
       )}
    end
  end

  def setup({:tenant, tenant_id}, %ExecutionContext{} = execution_context)
      when is_binary(tenant_id) do
    case Integer.parse(tenant_id) do
      {id, ""} -> setup({:tenant, id}, execution_context)
      _ -> {:error, "Invalid tenant id: #{inspect(tenant_id)}"}
    end
  end

  def setup({:tenant, tenant_id}, %ExecutionContext{} = execution_context)
      when is_integer(tenant_id) do
    {:ok,
     ScopeContext.new(
       mode: :tenant,
       scope: {:tenant, tenant_id},
       tenant: tenant_from_payload(tenant_id, execution_context.tenant)
     )}
  end

  def setup({:tenant, {:identifier, identifier}}, %ExecutionContext{} = _execution_context)
      when is_binary(identifier) and identifier != "" do
    {:ok,
     ScopeContext.new(
       mode: :tenant,
       scope: {:tenant, {:identifier, identifier}},
       tenant: TenantContext.new(identifier: identifier)
     )}
  end

  def setup({:global, nil}, %ExecutionContext{} = execution_context) do
    if is_nil(execution_context.tenant) do
      {:ok, ScopeContext.new(mode: :global, scope: {:global, nil}, tenant: nil)}
    else
      {:error, "Cannot be run in a tenant context"}
    end
  end

  def setup({:dynamic, nil}, %ExecutionContext{} = execution_context) do
    if is_nil(execution_context.tenant) do
      {:ok, ScopeContext.new(mode: :dynamic, scope: {:dynamic, nil}, tenant: nil)}
    else
      {:ok,
       ScopeContext.new(
         mode: :dynamic,
         scope: {:dynamic, nil},
         tenant: execution_context.tenant
       )}
    end
  end

  def setup(scope, _execution_context) do
    {:error, "Invalid scope: #{inspect(scope)}"}
  end

  # When payload tenant_id matches the already-resolved auth/host tenant, reuse it
  # so schema-prefix resolution can use the cached identifier without another lookup.
  defp tenant_from_payload(tenant_id, %TenantContext{id: tenant_id} = tenant)
       when not is_nil(tenant_id),
       do: tenant

  defp tenant_from_payload(tenant_id, _tenant), do: TenantContext.new(id: tenant_id)

  @doc "Like `setup/2`, but raises `Dobro.App.Scope.Error` on failure."
  @spec setup!(scope(), ExecutionContext.t()) :: ScopeContext.t()
  def setup!(scope, execution_context \\ %ExecutionContext{}) do
    case setup(scope, execution_context) do
      {:ok, scope_context} -> scope_context
      {:error, message} -> raise Error, message: message
    end
  end

  @doc """
  Resolves scope for a query struct from its module's `__scope__/0`.
  """
  def setup_for_query!(query, execution_context \\ %ExecutionContext{}) do
    query.__struct__.__scope__()
    |> resolve_query_scope!(query)
    |> setup!(execution_context)
  end

  defp resolve_query_scope!({:tenant, :payload}, query) do
    tenant_id = Map.get(query, :tenant_id)
    tenant_identifier = Map.get(query, :tenant_identifier)

    cond do
      not is_nil(tenant_id) ->
        {:tenant, tenant_id}

      is_binary(tenant_identifier) and tenant_identifier != "" ->
        {:tenant, {:identifier, tenant_identifier}}

      true ->
        raise Error,
              message:
                "tenant_id or tenant_identifier is required for tenant-scoped query #{inspect(query.__struct__)}"
    end
  end

  defp resolve_query_scope!(scope, _query), do: scope

  @doc false
  def validate_payload_scope!(module, scope, env) do
    case scope do
      {:tenant, :context} ->
        if :tenant_id in payload_field_names(module) do
          raise CompileError,
            description: """
            #{inspect(module)} declares `scope :tenant, from: :context` but its payload \
            includes `:tenant_id`. Tenant must come from the execution context only; remove \
            `:tenant_id` from the payload.
            """,
            file: env.file,
            line: env.line
        end

      _ ->
        :ok
    end
  end

  defp payload_field_names(module) do
    payload_module = Module.get_attribute(module, :payload_module) || module

    payload_module
    |> Module.get_attribute(:fields, accumulate: true)
    |> List.wrap()
    |> Enum.reverse()
  end
end
