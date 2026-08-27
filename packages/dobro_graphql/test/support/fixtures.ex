defmodule Dobro.Graphql.TestFixtures do
  @moduledoc false

  defmodule CategoryListItem do
    @moduledoc false
    use Dobro.Schema

    schema do
      field :id, :integer
      field :name, :string
      field :identifier, :string
      field :tenant_name, :string
    end
  end

  defmodule CategoryList do
    @moduledoc false
    use Dobro.Schema

    alias Dobro.Graphql.TestFixtures.CategoryListItem
    alias Dobro.Schema.ListOf

    schema do
      field :items, %ListOf{of_type: CategoryListItem}
      field :meta, :map
    end
  end
end
