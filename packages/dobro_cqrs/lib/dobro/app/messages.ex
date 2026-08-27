defmodule Dobro.App.Messages do
  @moduledoc false

  alias Dobro.Domain.Messages.MessageIdentity, as: DomainMessageIdentity

  defmodule MessageIdentity do
    @moduledoc false
    defdelegate new(value), to: DomainMessageIdentity
    defdelegate new!(value), to: DomainMessageIdentity
    defdelegate corresponding_to(message_identity), to: DomainMessageIdentity
    defdelegate corresponding_to(new_identity, message_identity), to: DomainMessageIdentity
  end
end

defmodule Dobro.App.Id do
  @moduledoc false
  defdelegate generate, to: Dobro.Domain.Id
end
