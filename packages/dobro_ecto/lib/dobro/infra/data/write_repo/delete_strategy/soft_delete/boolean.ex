defmodule Dobro.Infra.Data.WriteRepo.DeleteStrategy.SoftDelete.Boolean do
  @moduledoc """
  Soft-deletes by setting a boolean field on the persisted schema.
  """

  @behaviour Dobro.Infra.Data.WriteRepo.DeleteStrategy

  alias Dobro.Infra.Data.WriteRepo.UnitOfWork
  alias Dobro.Infra.Repo

  import Ecto.Changeset

  @impl Dobro.Infra.Data.WriteRepo.DeleteStrategy
  def delete(%UnitOfWork{schema: schema} = unit_of_work, _context, opts) do
    field = Keyword.fetch!(opts, :field)
    value = Keyword.get(opts, :value, true)
    repo_opts = Keyword.get(opts, :repo_opts, [])

    with {:ok, updated_schema} <-
           schema
           |> change(%{field => value})
           |> Repo.update(repo_opts) do
      {:ok, %{unit_of_work | schema: updated_schema}}
    end
  end
end
