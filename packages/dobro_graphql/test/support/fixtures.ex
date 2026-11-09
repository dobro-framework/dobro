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

  # Mutation returning: nested contracts (PeopleInvolved / RelatedPerson shape).
  defmodule RelatedPerson do
    @moduledoc false
    use Dobro.Schema

    schema do
      field :person_id, :id
      field :relationship, :string
    end
  end

  defmodule PeopleInvolved do
    @moduledoc false
    use Dobro.Schema

    alias Dobro.Graphql.TestFixtures.RelatedPerson
    alias Dobro.Schema.ListOf

    schema do
      field :id, :id
      field :case_id, :id
      field :comments, :string
      field :next_of_kin, RelatedPerson
      field :additional_contacts, %ListOf{of_type: RelatedPerson}
    end
  end
end
