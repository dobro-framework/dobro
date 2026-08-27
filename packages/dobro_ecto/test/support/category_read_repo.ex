defmodule Dobro.Ecto.Test.Ports.CategoryReadRepo do
  @moduledoc false
  use Dobro.Spec.Port

  @callback get_category(map(), map()) :: {:ok, term()} | {:error, term()}
  @callback list_categories(map(), map()) :: {:ok, map()} | {:error, term()}
end

defmodule Dobro.Ecto.Test.CategoryReadRepo do
  @moduledoc false

  import Ecto.Query

  alias Dobro.Ecto.Test.Schemas.CategorySchema

  use Dobro.Infra.Data.ReadRepo,
    port: Dobro.Ecto.Test.Ports.CategoryReadRepo,
    schema: CategorySchema,
    tenant_strategy: nil,
    scopes: [:global, :tenant]

  defquery GetCategory, type: :one do
    fields [:id, :name, :identifier, :deleted_at, :deleted, :status, :tenant_id]
    preload :tenant, Dobro.Ecto.Test.Schemas.TenantSchema, fields: [:id, :name]
  end

  defquery ListCategories, type: :list do
    fields [:id, :name, :identifier, :deleted_at, :deleted, :status, :tenant_id]
    filterable [:name]
    sortable [:name]

    query fn _args, _ctx ->
      from(c in schema(), as: :category)
    end
  end
end
