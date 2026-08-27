defmodule Dobro.Infra.Data.WriteRepo.DeleteStrategy.SoftDelete.DateTime do
  @moduledoc """
  Soft-deletes by setting a datetime field on the persisted schema.
  """

  @behaviour Dobro.Infra.Data.WriteRepo.DeleteStrategy

  alias Dobro.Infra.Data.WriteRepo.UnitOfWork
  alias Dobro.Infra.Repo

  import Ecto.Changeset

  @impl Dobro.Infra.Data.WriteRepo.DeleteStrategy
  def delete(%UnitOfWork{aggregate: aggregate, schema: schema} = unit_of_work, _context, opts) do
    field = Keyword.fetch!(opts, :field)
    repo_opts = Keyword.get(opts, :repo_opts, [])
    value = Map.get(aggregate, field) || Keyword.get(opts, :value) || DateTime.utc_now(:microsecond)

    with {:ok, updated_schema} <-
           schema
           |> change(%{field => value})
           |> Repo.update(repo_opts) do
      {:ok, %{unit_of_work | schema: updated_schema}}
    end
  end
end
