defmodule Dobro.Ecto.Test.Schemas.TenantSchema do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "dobro_test_tenants" do
    field :name, :string
    field :identifier, :string
    field :region_id, :integer
  end
end

defmodule Dobro.Ecto.Test.Schemas.CategorySchema do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "dobro_test_categories" do
    field :name, :string
    field :identifier, :string
    field :deleted_at, :utc_datetime_usec
    field :deleted, :boolean
    field :status, :string

    belongs_to :tenant, Dobro.Ecto.Test.Schemas.TenantSchema
  end
end

defmodule Dobro.Ecto.Test.Schemas.TemplateSchema do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "dobro_test_templates" do
    field :name, :string
    field :tenant_id, :integer
    field :category_id, :integer
    field :identifier, :string
    field :deleted_at, :utc_datetime_usec
    field :deleted, :boolean
    field :status, :string
  end
end

defmodule Dobro.Ecto.Test.Schemas.MappingSchema do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "dobro_test_mappings" do
    belongs_to :tenant, Dobro.Ecto.Test.Schemas.TenantSchema
    belongs_to :template, Dobro.Ecto.Test.Schemas.TemplateSchema
  end
end
