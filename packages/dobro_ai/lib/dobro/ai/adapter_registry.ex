defmodule Dobro.AI.AdapterRegistry do
  @moduledoc """
  Adapter registry for the Dobro AI package.
  """

  use Dobro.Spec.AdapterRegistry

  alias Dobro.AI.Infra.Providers.OpenAi

  register OpenAi
end
