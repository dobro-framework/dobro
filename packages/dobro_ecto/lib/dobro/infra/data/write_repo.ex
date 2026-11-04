defmodule Dobro.Infra.Data.WriteRepo do
  @moduledoc """
  This module provides a reusable repository implementation for managing the persistence of domain aggregates using Ecto schemas and mappers. It abstracts common CRUD operations and allows for easy integration with different domain models and database schemas.

  ## Usage

  Provide `aggregate`, `schema`, and optionally `tenant_strategy` — same atoms as
  `Dobro.Infra.Data.ReadRepo`:

  - `nil` / omit — no tenant handling (`NoTenantStrategy`)
  - `:tenant_id` — stamp `tenant_id` onto the changeset from write context
  - `:schema` — set Ecto repo `prefix` from write context

  Prefer declarative `mappings:` for domain ↔ schema translation; use `mapper:`
  only when you need custom mapping logic that mappings cannot express.

  When using a custom `mapper:` with `has_many` associations, pass
  `preloads: [:assoc_name]` so get/save round-trips load child rows.

  Example with association mappings:

      defmodule MyApp.Users.Infra.Data.UserWriteRepo do
        use Dobro.Infra.Data.WriteRepo,
          aggregate: MyApp.Users.Domain.User,
          schema: MyApp.Users.Infra.Data.UserSchema,
          tenant_strategy: :schema,
          mappings: [
            associations: [
              # id-list ↔ join rows
              role_ids: {:role_links, :role_id},
              # list_of(Entity) ↔ has_many (attrs only; cast_assoc in schema)
              lines: :order_lines
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

  Shared-schema (column) tenancy — tenant lives on the row, not the domain:

      use Dobro.Infra.Data.WriteRepo,
        aggregate: Case,
        schema: CaseSchema,
        tenant_strategy: :tenant_id

  `:mapper` and `:mappings` are mutually exclusive.
  """

  alias Dobro.Error
  alias Dobro.Infra.Data.WriteRepo.Definition
  alias Dobro.Infra.SchemaPrefix

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

    def context_for(opts) do
      tenant_id = Keyword.get(opts, :tenant_id)
      tenant_identifier = Keyword.get(opts, :tenant_identifier)

      %Context{
        tenant: %TenantContext{
          id: tenant_id,
          identifier: tenant_identifier
        }
      }
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

  defmodule NoTenantStrategy do
    @moduledoc """
    Strategy for write repos that do not have a tenant — mirrors ReadRepo.NoTenantStrategy.
    """

    def repo_opts(%Context{}), do: {:ok, []}

    def apply_to_changeset(changeset, %Context{}), do: {:ok, changeset}
  end

  defmodule TenantIdStrategy do
    @moduledoc """
    Strategy for write repos that store a tenant id column — mirrors ReadRepo.TenantIdStrategy.

    Stamps `tenant_id` onto the changeset from write context so domain aggregates
    need not carry storage tenancy.
    """

    def repo_opts(%Context{}), do: {:ok, []}

    def apply_to_changeset(changeset, %Context{} = context) do
      case tenant_id_from_context(context) do
        nil ->
          {:error,
           Error.new(:missing_tenant,
             description: "Tenant id is required for tenant_id write strategy"
           )}

        tenant_id ->
          changeset =
            changeset
            |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
            |> clear_field_error(:tenant_id)

          {:ok, changeset}
      end
    end

    # Domain aggregates do not carry tenant_id; schema validate_required may have
    # failed before the stamp. Clear that error once the column is set from context.
    defp clear_field_error(%Ecto.Changeset{} = changeset, field) do
      errors = Keyword.delete(changeset.errors, field)
      %{changeset | errors: errors, valid?: errors == []}
    end

    defp tenant_id_from_context(%Context{tenant: %{id: tenant_id}}), do: tenant_id
    defp tenant_id_from_context(_), do: nil
  end

  defmodule SchemaStrategy do
    @moduledoc """
    Strategy for write repos that use a schema per tenant — mirrors ReadRepo.SchemaStrategy.
    """

    def repo_opts(%Context{} = context), do: SchemaPrefix.repo_opts(context)

    def apply_to_changeset(changeset, %Context{}), do: {:ok, changeset}
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
