defmodule Dobro.Infra.Data.ReadRepo.Definition do
  @moduledoc """
  Generates read-repository functions for a schema and tenant strategy.
  """

  alias Dobro.Infra.Data.ReadRepo
  alias Dobro.Query.Tenant

  @doc "Returns quoted repo functions for the given `opts`."
  def functions(opts) do
    strategy_module = strategy_module_for(Keyword.get(opts, :tenant_strategy))
    context_mode = Keyword.get(opts, :context_mode, context_mode_for(strategy_module))
    soft_delete = Keyword.get(opts, :soft_delete)

    case Keyword.get(opts, :schema) do
      nil ->
        quote do
          unquote(context_mode_function(context_mode))
        end

      schema_module ->
        quote do
          unquote(strategy_functions(strategy_module, schema_module, soft_delete))
          unquote(query_functions())
          unquote(context_mode_function(context_mode))
        end
    end
  end

  defp context_mode_function(context_mode) do
    quote do
      @context_mode unquote(context_mode)
      def context_mode, do: @context_mode
    end
  end

  defp context_mode_for(Dobro.Infra.Data.ReadRepo.NoTenantStrategy), do: :none
  defp context_mode_for(Dobro.Infra.Data.ReadRepo.SchemaStrategy), do: :tenant
  defp context_mode_for(Dobro.Infra.Data.ReadRepo.TenantIdStrategy), do: :tenant

  defp context_mode_for(strategy),
    do: raise("Invalid tenant strategy module: #{inspect(strategy)}")

  defp strategy_functions(strategy_module, schema_module, soft_delete) do
    schema_body =
      if soft_delete do
        quote do
          Dobro.Infra.Data.ReadRepo.SoftDeleteFilter.exclude_deleted(
            unquote(schema_module),
            unquote(Macro.escape(soft_delete))
          )
        end
      else
        quote do
          unquote(schema_module)
        end
      end

    quote do
      def strategy, do: unquote(strategy_module)

      def schema, do: unquote(schema_body)

      def fetch(queryable, id, opts \\ []) do
        strategy().get(queryable, schema(), id, opts)
        |> wrap_result(schema())
      end

      def get_by(queryable, clauses, opts \\ []) do
        strategy().get_by(queryable, schema(), clauses, opts)
        |> wrap_result(schema())
      end

      def exists?(queryable, opts \\ []) do
        strategy().exists?(queryable, schema(), opts)
      end

      def one(queryable, opts \\ []) do
        strategy().one(queryable, schema(), opts)
        |> wrap_result(schema())
      end
    end
  end

  defp query_functions do
    quote do
      def all(queryable, opts \\ []) do
        strategy().all(queryable, schema(), opts)
      end

      def aggregate(queryable, aggregate, opts \\ []) do
        strategy().aggregate(queryable, schema(), aggregate, opts)
      end

      def list(queryable, query \\ nil, opts \\ []) do
        strategy().list(queryable, schema(), query, opts)
      end

      def maybe_apply_tenant(queryable, tenant_id, opts \\ []) do
        opts = ReadRepo.tenant_query_opts(schema(), opts)
        Tenant.maybe_apply_tenant(queryable, tenant_id, opts)
      end

      def where_eq(queryable, field, value) do
        Dobro.Query.where_eq(queryable, field, value)
      end
    end
  end

  defp strategy_module_for(nil), do: Dobro.Infra.Data.ReadRepo.NoTenantStrategy
  defp strategy_module_for(:tenant_id), do: Dobro.Infra.Data.ReadRepo.TenantIdStrategy
  defp strategy_module_for(:schema), do: Dobro.Infra.Data.ReadRepo.SchemaStrategy

  defp strategy_module_for(strategy),
    do: raise("Invalid tenant strategy: #{strategy}")
end
