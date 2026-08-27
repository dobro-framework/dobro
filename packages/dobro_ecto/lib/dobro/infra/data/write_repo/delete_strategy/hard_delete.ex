defmodule Dobro.Infra.Data.WriteRepo.DeleteStrategy.HardDelete do
  @moduledoc """
  Physically removes the persisted schema row while retaining the in-memory aggregate.
  """

  @behaviour Dobro.Infra.Data.WriteRepo.DeleteStrategy

  alias Dobro.Error
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork
  alias Dobro.Infra.Repo

  @impl Dobro.Infra.Data.WriteRepo.DeleteStrategy
  def delete(%UnitOfWork{aggregate: _aggregate, schema: nil}, _context, _opts) do
    {:error, Error.new(:already_deleted)}
  end

  def delete(%UnitOfWork{aggregate: aggregate, schema: schema}, _context, opts) do
    repo_opts = Keyword.get(opts, :repo_opts, [])

    case Repo.delete(schema, repo_opts) do
      {:ok, _deleted} -> {:ok, UnitOfWork.new(%{aggregate: aggregate, schema: nil})}
      {:error, error} -> {:error, error}
    end
  end
end
