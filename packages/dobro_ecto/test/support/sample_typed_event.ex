defmodule Dobro.TestSupport.SampleContact do
  @moduledoc false
  use Dobro.Domain.ValueObject

  schema do
    field :person_id, :id, required: true
    field :relationship, :string
  end
end

defmodule Dobro.TestSupport.SampleTypedEvents do
  @moduledoc false
  use Dobro.Domain.EventDefinition

  alias Dobro.TestSupport.SampleContact

  defevent ContactUpdated do
    payload do
      field :name, :string
      field :contact, SampleContact
      field :contacts, list_of(SampleContact)
    end
  end
end
