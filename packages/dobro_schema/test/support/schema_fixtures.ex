defmodule Dobro.Schema.TestFixtures do
  @moduledoc false

  defmodule StringList do
    @moduledoc false
    use Dobro.Schema

    alias Dobro.Contract.Helpers

    schema do
      field :values, list_of(non_null(:string)), required: true
    end

    def new(value), do: Helpers.new(__MODULE__, value)
  end

  defmodule TaggedItem do
    @moduledoc false
    use Dobro.Schema

    alias Dobro.Contract.Helpers

    schema do
      field :label, non_null(:string), required: true
      field :tags, list_of(non_null(:string)), required: true
    end

    def new(value), do: Helpers.new(__MODULE__, value)
  end

  defmodule TaggedItemList do
    @moduledoc false
    use Dobro.Schema

    alias Dobro.Contract.Helpers
    alias Dobro.Schema.TestFixtures.TaggedItem

    schema do
      field :items, list_of(TaggedItem), required: true
    end

    def new(value), do: Helpers.new(__MODULE__, value)
  end
end
