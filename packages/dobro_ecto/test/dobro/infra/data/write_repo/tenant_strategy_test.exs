defmodule Dobro.Infra.Data.WriteRepo.TenantStrategyTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext
  alias Dobro.Error
  alias Dobro.Infra.Data.WriteRepo
  alias Dobro.Infra.Data.WriteRepo.Context

  defmodule Item do
    defstruct [:id, :name, :version]

    def __schema__, do: [id: {:id, []}, name: {:string, []}, version: {:integer, []}]
    def __identity_fields__, do: [:id]
  end

  defmodule ItemSchema do
    use Ecto.Schema
    import Ecto.Changeset

    schema "items" do
      field :name, :string
      field :tenant_id, :integer
      field :version, :integer, default: 0
    end

    def changeset(struct, attrs) do
      struct
      |> cast(attrs, [:name, :tenant_id, :version])
      |> validate_required([:name])
    end
  end

  defmodule NoTenantWriteRepo do
    use Dobro.Infra.Data.WriteRepo,
      aggregate: Item,
      schema: ItemSchema
  end

  defmodule TenantIdWriteRepo do
    use Dobro.Infra.Data.WriteRepo,
      aggregate: Item,
      schema: ItemSchema,
      tenant_strategy: :tenant_id
  end

  defmodule SchemaWriteRepo do
    use Dobro.Infra.Data.WriteRepo,
      aggregate: Item,
      schema: ItemSchema,
      tenant_strategy: :schema
  end

  test "tenant_strategy atoms resolve to the same strategy names as ReadRepo" do
    assert NoTenantWriteRepo.strategy() == WriteRepo.NoTenantStrategy
    assert TenantIdWriteRepo.strategy() == WriteRepo.TenantIdStrategy
    assert SchemaWriteRepo.strategy() == WriteRepo.SchemaStrategy
  end

  test "TenantIdStrategy stamps tenant_id from write context" do
    changeset = ItemSchema.changeset(%ItemSchema{}, %{name: "a"})
    context = Context.new(tenant: TenantContext.new(%{id: 42, identifier: "acme"}))

    assert {:ok, stamped} = WriteRepo.TenantIdStrategy.apply_to_changeset(changeset, context)
    assert Ecto.Changeset.get_change(stamped, :tenant_id) == 42
  end

  test "TenantIdStrategy clears a prior tenant_id required error after stamping" do
    changeset =
      %ItemSchema{}
      |> ItemSchema.changeset(%{name: "a"})
      |> Map.put(:errors, tenant_id: {"can't be blank", [validation: :required]})
      |> Map.put(:valid?, false)

    context = Context.new(tenant: TenantContext.new(%{id: 7, identifier: "acme"}))

    assert {:ok, stamped} = WriteRepo.TenantIdStrategy.apply_to_changeset(changeset, context)
    assert stamped.valid?
    assert Ecto.Changeset.get_change(stamped, :tenant_id) == 7
    refute Keyword.has_key?(stamped.errors, :tenant_id)
  end

  test "TenantIdStrategy errors when tenant id is missing" do
    changeset = ItemSchema.changeset(%ItemSchema{}, %{name: "a"})
    context = Context.new(tenant: nil)

    assert {:error, %Error{reason: :missing_tenant}} =
             WriteRepo.TenantIdStrategy.apply_to_changeset(changeset, context)
  end

  test "TenantIdStrategy scopes loads to the context tenant" do
    context = Context.new(tenant: TenantContext.new(%{id: 42, identifier: "acme"}))

    assert {:ok, query} = WriteRepo.TenantIdStrategy.scope(ItemSchema, context)
    assert [%{expr: expr, params: [{42, _}]}] = query.wheres
    assert Macro.to_string(expr) =~ "tenant_id"
  end

  test "TenantIdStrategy refuses to load without a tenant" do
    assert {:error, %Error{reason: :missing_tenant}} =
             WriteRepo.TenantIdStrategy.scope(ItemSchema, Context.new(tenant: nil))
  end

  test "SchemaStrategy and NoTenantStrategy load without a tenant filter" do
    context = Context.new(tenant: TenantContext.new(%{id: 1, identifier: "acme"}))

    assert {:ok, ItemSchema} = WriteRepo.NoTenantStrategy.scope(ItemSchema, context)
    assert {:ok, ItemSchema} = WriteRepo.SchemaStrategy.scope(ItemSchema, context)
  end

  test "SchemaStrategy and NoTenantStrategy leave the changeset unchanged" do
    changeset = ItemSchema.changeset(%ItemSchema{}, %{name: "a"})
    context = Context.new(tenant: TenantContext.new(%{id: 1, identifier: "acme"}))

    assert {:ok, ^changeset} = WriteRepo.NoTenantStrategy.apply_to_changeset(changeset, context)
    assert {:ok, ^changeset} = WriteRepo.SchemaStrategy.apply_to_changeset(changeset, context)
  end
end
