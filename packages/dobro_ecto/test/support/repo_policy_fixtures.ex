defmodule Dobro.Ecto.Test.RepoPolicyFixtures do
  @moduledoc false

  alias Dobro.Infra.Data.ReadRepo

  defmodule GlobalRepo do
    @moduledoc false
    @allowed_scopes [:global]

    def __allowed_scopes__, do: @allowed_scopes
    def strategy, do: ReadRepo.NoTenantStrategy
  end

  defmodule TenantIdRepo do
    @moduledoc false
    @allowed_scopes [:tenant]

    def __allowed_scopes__, do: @allowed_scopes
    def strategy, do: ReadRepo.TenantIdStrategy
  end

  defmodule SchemaTenantRepo do
    @moduledoc false
    @allowed_scopes [:tenant]

    def __allowed_scopes__, do: @allowed_scopes
    def strategy, do: ReadRepo.SchemaStrategy
  end
end
