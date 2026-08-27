defmodule Dobro.Domain.TestFixtures do
  @moduledoc false

  defmodule Tag do
    @moduledoc false
    use Dobro.Domain.ValueObject

    schema do
      field :name, non_null(:string), required: true
      field :values, list_of(non_null(:string)), required: true
    end
  end
end
