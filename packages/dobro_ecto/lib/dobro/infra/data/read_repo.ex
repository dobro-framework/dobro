defmodule Dobro.Infra.Data.ReadRepo do
  @moduledoc """
  Read repo adapter module
  """
  alias Dobro.Infra.Data.ReadRepo.Definition
  alias Dobro.Infra.SchemaPrefix

  defmodule Context do
    @moduledoc """
    Context struct for read repos
    """
    use TypedStruct

    alias Dobro.App.Auth.TenantContext
    alias Dobro.App.Selection

    typedstruct do
      field :tenant, TenantContext.t()
      field :selection, Selection.t()
    end

    def new(attrs) do
      struct(__MODULE__, attrs)
    end
  end

  defmacro __using__(opts \\ []) do
    port = Keyword.fetch!(opts, :port)
    caller = __CALLER__.module

    allowed_scopes = Keyword.get(opts, :scopes, [:global, :tenant])
    context_mode = Keyword.get(opts, :context_mode)

    {schema_quote, definition_opts} =
      case Keyword.get(opts, :schema) do
        nil ->
          {quote(do: @read_repo_schema nil), opts}

        schema ->
          schema_module = Macro.expand(schema, __CALLER__)

          Module.register_attribute(caller, :read_repo_schema, persist: true)
          Module.put_attribute(caller, :read_repo_schema, schema_module)

          {quote(do: @read_repo_schema unquote(schema_module)), Keyword.put(opts, :schema, schema_module)}
      end

    opts =
      if context_mode,
        do: Keyword.put(definition_opts, :context_mode, context_mode),
        else: definition_opts

    query_defaults = query_defaults(opts)
    mappings = Dobro.Infra.Data.Mappings.normalize(Keyword.get(opts, :mappings))

    Module.register_attribute(caller, :read_repo_query_defaults, persist: true)
    Module.put_attribute(caller, :read_repo_query_defaults, query_defaults)

    quote location: :keep do
      use Dobro.Spec.Adapter, port: unquote(port)

      import Ecto.Query
      import Dobro.Infra.Data.ReadRepo.Helpers

      unquote(schema_quote)
      @allowed_scopes unquote(allowed_scopes)
      @read_repo_query_defaults unquote(Macro.escape(query_defaults))
      @read_repo_mappings unquote(Macro.escape(mappings))

      use Dobro.Infra.Data.Query.Definition

      def run(query_module, args, context \\ nil) do
        Dobro.Infra.Data.Query.Runner.run(__MODULE__, query_module, args, context)
      end

      def __allowed_scopes__, do: @allowed_scopes

      def __query_defaults__, do: @read_repo_query_defaults

      def __mappings__, do: @read_repo_mappings

      unquote(Definition.functions(opts))
    end
  end

  @doc """
  Returns query defaults from `use ReadRepo` options.

  Set via `query_defaults: [include_global: false]` (overridable per `defquery`).
  """
  def query_defaults(opts), do: Keyword.get(opts, :query_defaults, [])

  def functions(opts), do: Definition.functions(opts)

  def tenant_query_opts(schema_module, opts) do
    if function_exported?(schema_module, :key, 0) do
      Keyword.merge([key: schema_module.key()], opts)
    else
      opts
    end
  end

  defmodule Helpers do
    @moduledoc """
    Helpers for read repo strategies
    """

    @doc """
    Returns an atom named after the schema module (last part, snake_cased) and suffixed with _not_found
    """
    def not_found_error(schema_module) do
      name =
        schema_module
        |> Module.split()
        |> List.last()
        |> String.replace(~r/Schema$/, "")
        |> Macro.underscore()

      [name, "not_found"]
      |> Enum.join("_")
      |> String.to_atom()
    end

    def wrap_result(result, schema_module) do
      case result do
        {:error, error} ->
          {:error, error}

        nil ->
          {:error, not_found_error(schema_module)}

        result ->
          {:ok, result}
      end
    end

    def put_tenant_id(%Context{} = context, tenant_id) do
      put_in(context.tenant.id, tenant_id)
    end

    def put_tenant_identifier(%Context{} = context, tenant_identifier) do
      put_in(context.tenant.identifier, tenant_identifier)
    end

    def context_for(opts) do
      tenant_id = Keyword.get(opts, :tenant_id)
      tenant_identifier = Keyword.get(opts, :tenant_identifier)

      %Context{}
      |> put_tenant_id(tenant_id)
      |> put_tenant_identifier(tenant_identifier)
    end
  end

  defmodule NoTenantStrategy do
    @moduledoc """
    Strategy for read repos that do not have a tenant
    """

    def get(queryable, _schema_module, id, _opts \\ []) do
      queryable
      |> Dobro.Infra.Repo.get(id)
    end

    def get_by(queryable, _schema_module, clauses, _opts \\ []) do
      queryable
      |> Dobro.Infra.Repo.get_by(clauses)
    end

    def exists?(queryable, _schema_module, _opts \\ []) do
      queryable
      |> Dobro.Infra.Repo.exists?()
    end

    def one(queryable, _schema_module, _opts \\ []) do
      queryable
      |> Dobro.Infra.Repo.one()
    end

    def all(queryable, _schema_module, _opts \\ []) do
      queryable
      |> Dobro.Infra.Repo.all()
    end

    def aggregate(queryable, _schema_module, aggregate, _opts \\ []) do
      queryable
      |> Dobro.Infra.Repo.aggregate(aggregate)
    end

    def list(queryable, schema_module, query, _opts \\ []) do
      queryable
      |> Dobro.Query.validate_and_run(query, for: schema_module)
    end
  end

  defmodule TenantIdStrategy do
    @moduledoc """
    Strategy for read repos that have a tenant id - requires that a tenant id is present in the context
    """
    alias Dobro.Query

    def get(
          queryable,
          schema_module,
          id,
          opts \\ []
        ) do
      queryable
      |> Query.Tenant.apply_tenant!(
        tenant_id_from_context(context_from_opts(opts)),
        prepare_opts(schema_module, opts)
      )
      |> Dobro.Infra.Repo.get(id)
    end

    def get_by(
          queryable,
          schema_module,
          clauses,
          opts \\ []
        ) do
      queryable
      |> Query.Tenant.apply_tenant!(
        tenant_id_from_context(context_from_opts(opts)),
        prepare_opts(schema_module, opts)
      )
      |> Dobro.Infra.Repo.get_by(clauses)
    end

    def exists?(
          queryable,
          schema_module,
          opts \\ []
        ) do
      queryable
      |> Query.Tenant.apply_tenant!(
        tenant_id_from_context(context_from_opts(opts)),
        prepare_opts(schema_module, opts)
      )
      |> Dobro.Infra.Repo.exists?()
    end

    def one(queryable, schema_module, opts \\ []) do
      queryable
      |> Query.Tenant.apply_tenant!(
        tenant_id_from_context(context_from_opts(opts)),
        prepare_opts(schema_module, opts)
      )
      |> Dobro.Infra.Repo.one()
    end

    def all(queryable, schema_module, opts \\ []) do
      queryable
      |> Query.Tenant.apply_tenant!(
        tenant_id_from_context(context_from_opts(opts)),
        prepare_opts(schema_module, opts)
      )
      |> Dobro.Infra.Repo.all()
    end

    def aggregate(queryable, schema_module, aggregate, opts \\ []) do
      queryable
      |> Query.Tenant.apply_tenant!(
        tenant_id_from_context(context_from_opts(opts)),
        prepare_opts(schema_module, opts)
      )
      |> Dobro.Infra.Repo.aggregate(aggregate)
    end

    def list(
          queryable,
          schema_module,
          query,
          opts \\ []
        ) do
      queryable
      |> Query.Tenant.apply_tenant!(
        tenant_id_from_context(context_from_opts(opts)),
        prepare_opts(schema_module, opts)
      )
      |> Dobro.Query.validate_and_run(query, for: schema_module)
    end

    defp prepare_opts(schema_module, opts) do
      base =
        if function_exported?(schema_module, :key, 0),
          do: [key: schema_module.key()],
          else: []

      base
      |> Keyword.merge(opts)
      |> Keyword.take([:key, :include_global])
    end

    defp context_from_opts(opts) do
      Keyword.get(opts, :context, %Context{})
    end

    defp tenant_id_from_context(%Context{} = context) do
      case context.tenant do
        %{id: tenant_id} -> tenant_id
        nil -> nil
      end
    end
  end

  defmodule SchemaStrategy do
    @moduledoc """
    Strategy for read repos that have a schema per tenant - requires that a tenant is present in the context
    """

    def get(queryable, _schema_module, id, opts) do
      context = context_from_opts(opts)

      with {:ok, opts} <- SchemaPrefix.repo_opts(context) do
        queryable
        |> Dobro.Infra.Repo.get(id, opts)
      end
    end

    def get_by(queryable, _schema_module, clauses, opts) do
      context = context_from_opts(opts)

      with {:ok, opts} <- SchemaPrefix.repo_opts(context) do
        queryable
        |> Dobro.Infra.Repo.get_by(clauses, opts)
      end
    end

    def exists?(queryable, _schema_module, opts) do
      context = context_from_opts(opts)

      with {:ok, opts} <- SchemaPrefix.repo_opts(context) do
        queryable
        |> Dobro.Infra.Repo.exists?(opts)
      end
    end

    def one(queryable, _schema_module, opts) do
      context = context_from_opts(opts)

      with {:ok, opts} <- SchemaPrefix.repo_opts(context) do
        queryable
        |> Dobro.Infra.Repo.one(opts)
      end
    end

    def all(queryable, _schema_module, opts) do
      context = context_from_opts(opts)

      with {:ok, opts} <- SchemaPrefix.repo_opts(context) do
        queryable
        |> Dobro.Infra.Repo.all(opts)
      end
    end

    def aggregate(queryable, _schema_module, aggregate, opts) do
      context = context_from_opts(opts)

      with {:ok, opts} <- SchemaPrefix.repo_opts(context) do
        queryable
        |> Dobro.Infra.Repo.aggregate(aggregate, opts)
      end
    end

    def list(queryable, schema_module, query, opts) do
      context = context_from_opts(opts)

      with {:ok, opts} <- SchemaPrefix.repo_opts(context) do
        queryable
        |> Dobro.Query.validate_and_run(query, for: schema_module, query_opts: opts)
      end
    end

    defp context_from_opts(opts) do
      Keyword.get(opts, :context, %Context{})
    end
  end

  defmodule PortDefinition do
    @moduledoc """
    Port definition helper for write operations
    """
    defmacro __using__(opts \\ []) do
      quote do
        @moduledoc """
        Port definition for read operations
        """
        use Dobro.Spec.Port, unquote(opts)

        alias Dobro.Infra.Data.ReadRepo.Context

        @optional_callbacks get: 2, get_by: 2, all: 1, exists?: 2, one: 2

        @callback get(term(), Context.t()) :: {:ok, term()} | {:error, term()}
        @callback get_by(map(), Context.t()) :: {:ok, term()} | {:error, term()}
        @callback all(Context.t()) :: [term()]
        @callback exists?(term(), Context.t()) :: boolean()
        @callback one(term(), Context.t()) :: {:ok, term()} | {:error, term()}
      end
    end
  end
end
