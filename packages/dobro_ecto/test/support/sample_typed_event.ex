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

  defevent StatusTransitioned do
    payload do
      field :id, :id
      field :lifecycle_status, :string
      field :occurred_at, :datetime

      field :original, Original do
        field :lifecycle_status, :string
      end
    end
  end
end
