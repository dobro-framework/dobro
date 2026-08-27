defmodule Dobro.Infra.Data.WriteRepo.Definition do
  @moduledoc """
  Generates write-repository CRUD functions for an aggregate and schema pair.
  """

  alias Dobro.Error
  alias Dobro.Infra.Data.WriteRepo.DeleteStrategy
  alias Dobro.Infra.Data.WriteRepo.Mappings
  alias Dobro.Infra.Data.WriteRepo.{Context, UnitOfWork}
  alias Dobro.Infra.SchemaPrefix
  alias Dobro.Infra.Repo

  @doc "Returns quoted write-repo functions for the given `opts`."
  def functions(opts) do
    {strategy_module, strategy_opts} = DeleteStrategy.resolve(Keyword.get(opts, :on_delete, :hard_delete))
    repo_module = Keyword.fetch!(opts, :repo_module)
    {mapper_setup_ast, preloads} = Mappings.resolve(opts, repo_module)

    quote do
      unquote(mapper_setup_ast)

      unquote(tenant_functions(opts))
      unquote(mapping_functions(opts))
      unquote(preload_functions(preloads))
      unquote(persistence_functions(opts))
      unquote(delete_function(strategy_module, strategy_opts))
      unquote(all_function(opts))
      unquote(first_function(opts))
      unquote(get_functions(opts))
    end
  end

  defp tenant_functions(opts) do
    if Keyword.get(opts, :tenant_strategy) == :schema do
      quote do
        defp repo_opts(%Context{} = context) do
          SchemaPrefix.repo_opts(context)
        end

        defp context_for(opts) do
          tenant_id = Keyword.get(opts, :tenant_id)
          tenant_identifier = Keyword.get(opts, :tenant_identifier)

          %Context{
            tenant: %Dobro.App.Auth.TenantContext{
              id: tenant_id,
              identifier: tenant_identifier
            }
          }
        end
      end
    else
      quote do
        defp repo_opts(%Context{} = _context), do: {:ok, []}
      end
    end
  end

  defp mapping_functions(opts) do
    schema_module = Keyword.fetch!(opts, :schema)
    aggregate_module = Keyword.fetch!(opts, :aggregate)

    quote do
      def to_changeset(%unquote(aggregate_module){} = aggregate) do
        to_changeset(aggregate, %unquote(schema_module){id: aggregate.id})
      end

      def to_domain(schema) do
        to_domain(schema, unquote(aggregate_module))
      end

      defp to_unit_of_work(schema) do
        case to_domain(schema) do
          {:ok, aggregate} ->
            {:ok,
             UnitOfWork.new(%{
               schema: schema,
               aggregate: aggregate
             })}

          {:error, error} ->
            {:error, error}
        end
      end
    end
  end

  defp preload_functions([]) do
    quote do
      defp maybe_preload(nil, _opts), do: nil
      defp maybe_preload(schema, _opts), do: schema
    end
  end

  defp preload_functions(preloads) do
    quote do
      defp maybe_preload(nil, _opts), do: nil

      defp maybe_preload(schema, opts) do
        Repo.preload(schema, unquote(preloads), opts)
      end
    end
  end

  defp persistence_functions(_opts) do
    quote do
      def insert(%UnitOfWork{aggregate: aggregate}, %Context{} = context) do
        with {:ok, %Ecto.Changeset{} = changeset} <- to_changeset(aggregate),
             {:ok, opts} <- repo_opts(context),
             {:ok, schema} <- Repo.insert(changeset, opts) do
          schema
          |> maybe_preload(opts)
          |> to_unit_of_work()
        else
          {:error, error} -> {:error, error}
        end
      end

      def update(
            %UnitOfWork{aggregate: aggregate, schema: schema},
            %Context{} = context
          ) do
        with {:ok, %Ecto.Changeset{} = changeset} <- to_changeset(aggregate, schema),
             {:ok, opts} <- repo_opts(context),
             {:ok, %_{} = schema} <- Repo.update(changeset, opts) do
          schema
          |> maybe_preload(opts)
          |> to_unit_of_work()
        end
      end

      def save(%UnitOfWork{} = unit_of_work, %Context{} = context) do
        if is_nil(unit_of_work.aggregate.id) do
          insert(unit_of_work, context)
        else
          update(unit_of_work, context)
        end
      end
    end
  end

  defp delete_function(strategy_module, strategy_opts) do
    quote do
      def delete(%UnitOfWork{} = unit_of_work, %Context{} = context) do
        with {:ok, repo_opts} <- repo_opts(context) do
          strategy_opts =
            unquote(Macro.escape(strategy_opts))
            |> Keyword.put(:repo_opts, repo_opts)

          unquote(strategy_module).delete(unit_of_work, context, strategy_opts)
        end
      end
    end
  end

  defp all_function(opts) do
    schema_module = Keyword.fetch!(opts, :schema)

    quote do
      def all(%Context{} = context) do
        with {:ok, opts} <- repo_opts(context) do
          Repo.all(unquote(schema_module), opts)
          |> Enum.map(&maybe_preload(&1, opts))
          |> Enum.map(&to_unit_of_work/1)
        end
      end
    end
  end

  defp first_function(opts) do
    schema_module = Keyword.fetch!(opts, :schema)

    quote do
      def first(%Context{} = context) do
        with {:ok, opts} <- repo_opts(context) do
          case Repo.one(unquote(schema_module), opts) |> maybe_preload(opts) do
            nil -> {:error, Error.new(:not_found, context: {__MODULE__, :first})}
            schema -> to_unit_of_work(schema)
          end
        end
      end
    end
  end

  defp get_functions(opts) do
    schema_module = Keyword.fetch!(opts, :schema)

    quote do
      def get(id, %Context{} = context) do
        with {:ok, opts} <- repo_opts(context) do
          case Repo.get(unquote(schema_module), id, opts) |> maybe_preload(opts) do
            nil -> {:error, Error.new(:not_found, context: {__MODULE__, :get})}
            schema -> to_unit_of_work(schema)
          end
        end
      end

      def get_by(%{} = identity, %Context{} = context) do
        with {:ok, opts} <- repo_opts(context) do
          case Repo.get_by(unquote(schema_module), identity, opts) |> maybe_preload(opts) do
            nil -> {:error, Error.new(:not_found, context: {__MODULE__, :get_by})}
            schema -> to_unit_of_work(schema)
          end
        end
      end
    end
  end
end
