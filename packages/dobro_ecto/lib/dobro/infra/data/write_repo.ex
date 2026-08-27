defmodule Dobro.Infra.Data.WriteRepo do
  @moduledoc """
  This module provides a reusable repository implementation for managing the persistence of domain aggregates using Ecto schemas and mappers. It abstracts common CRUD operations and allows for easy integration with different domain models and database schemas.

  ## Usage

  Provide `aggregate`, `schema`, and optionally `tenant_strategy`. Prefer declarative
  `mappings:` for domain ↔ schema translation; use `mapper:` only when you need custom
  mapping logic that mappings cannot express.

  Example with association mappings:

      defmodule MyApp.Users.Infra.Data.UserWriteRepo do
        use Dobro.Infra.Data.WriteRepo,
          aggregate: MyApp.Users.Domain.User,
          schema: MyApp.Users.Infra.Data.UserSchema,
          tenant_strategy: :schema,
          mappings: [
            associations: [
              role_ids: {:role_links, :role_id}
            ]
          ]
      end

  Example with field mappings (embed / jsonb / renamed columns):

      use Dobro.Infra.Data.WriteRepo,
        aggregate: Office,
        schema: OfficeSchema,
        tenant_strategy: :schema,
        mappings: [
          fields: [
            abbreviation: {:in, :json_attributes},
            phone_number: {:in, :json_attributes},
            address: {:in, :json_attributes}
          ]
        ]

  `:mapper` and `:mappings` are mutually exclusive.
  """

  alias Dobro.Infra.Data.WriteRepo.Definition

  defmodule Context do
    @moduledoc """
    Context for write operations
    """
    use TypedStruct

    alias Dobro.App.Auth.TenantContext

    typedstruct do
      field :tenant, TenantContext.t()
    end

    def new(attrs) do
      struct(__MODULE__, attrs)
    end
  end

  defmodule UnitOfWork do
    @moduledoc """
    Unit of work for write operations
    """
    use TypedStruct

    typedstruct do
      field :aggregate, term()
      field :schema, term()
    end

    def new(attrs) do
      struct(__MODULE__, attrs)
    end
  end

  defmacro __using__(opts) do
    aggregate_module = Keyword.fetch!(opts, :aggregate)

    delete_strategy =
      expand_delete_strategy(Keyword.get(opts, :on_delete, :hard_delete), __CALLER__)

    operations =
      Keyword.get(opts, :operations, [:insert, :update, :delete, :save, :all, :get, :get_by])

    transactional = Keyword.get(opts, :transactional, true)

    opts =
      opts
      |> Keyword.put(:on_delete, delete_strategy)
      |> Keyword.put(:repo_module, __CALLER__.module)

    quote location: :keep do
      use Dobro.Spec.Adapter,
        port: Dobro.Infra.Data.WriteRepo.Port,
        for: [aggregate: unquote(aggregate_module), operations: unquote(operations)]

      @doc """
      Whether this adapter participates in Postgres transactions.

      Not part of `WriteRepo.Port` (so Mox port mocks are unaffected). Remote/HTTP
      adapters should set `transactional: false` or define `transactional?/0` as
      false so `Dobro.App.Command.Commit` does not hold a DB connection across the
      network call. Defaults to true when the function is absent.
      """
      def transactional?, do: unquote(transactional)

      unquote(Definition.functions(opts))
    end
  end

  defp expand_delete_strategy({mod, strategy_opts}, env) when is_list(strategy_opts) do
    {Macro.expand(mod, env), strategy_opts}
  end

  defp expand_delete_strategy(strategy, _env), do: strategy

  defmodule PortDefinition do
    @moduledoc """
    Port definition helper for write operations
    """
    defmacro __using__(opts \\ []) do
      quote do
        @moduledoc """
        Port definition for write operations
        """
        use Dobro.Spec.Port, unquote(opts)
        alias Dobro.Infra.Data.WriteRepo.{Context, UnitOfWork}

        @callback get(integer(), Context.t()) :: {:ok, term()} | {:error, term()}
        @callback all(Context.t()) :: [term()]
        @callback save(term(), Context.t()) :: {:ok, term()} | {:error, term()}
        @callback insert(term(), Context.t()) :: {:ok, term()} | {:error, term()}
        @callback update(term(), Context.t()) :: {:ok, term()} | {:error, term()}
        @callback delete(term(), Context.t()) :: {:ok, term()} | {:error, term()}
      end
    end
  end

  defmodule Port do
    @moduledoc """
    Port for write operations
    Matches on the aggregate and operation
    """

    alias Dobro.Infra.Data.WriteRepo.Context

    use Dobro.Spec.Port,
      match: fn port_opts, adapter_opts ->
        port_aggregate = Keyword.get(port_opts, :aggregate)
        port_operations = Keyword.get(port_opts, :operations)
        aggregate = Keyword.get(adapter_opts, :aggregate)
        operation = Keyword.get(adapter_opts, :operation)

        port_aggregate == aggregate && operation in port_operations
      end

    @callback save(term(), Context.t()) :: {:ok, term()} | {:error, term()}
    @callback insert(term(), Context.t()) :: {:ok, term()} | {:error, term()}
    @callback update(term(), Context.t()) :: {:ok, term()} | {:error, term()}
    @callback delete(term(), Context.t()) :: {:ok, term()} | {:error, term()}
    @callback all(Context.t()) :: [term()]
    @callback first(Context.t()) :: {:ok, term()} | {:error, term()}
    @callback get(integer(), Context.t()) :: {:ok, term()} | {:error, term()}
    @callback get_by(map(), Context.t()) :: {:ok, term()} | {:error, term()}
  end
end
