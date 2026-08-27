defmodule Dobro.Infra.Data.WriteRepo.Persist do
  @moduledoc """
  Persists aggregate state through WriteRepo ports.

  Does not enrich domain events or publish them — those are application-layer
  concerns handled by `Dobro.App.Command.EventEnrichment` and event delivery strategies.
  """

  use Dobro.Spec.Consumer, ports: [write_repo: Dobro.Infra.Data.WriteRepo.Port]

  alias Dobro.Error
  alias Dobro.Infra.Data.RepoContext
  alias Dobro.Infra.Data.WriteRepo.Operation
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  @doc """
  Saves aggregate state and returns the updated unit of work.
  """
  @spec save(UnitOfWork.t(), [term()], term()) :: {:ok, UnitOfWork.t()} | {:error, term()}
  def save(unit_of_work, events, tenant) do
    operation = Operation.resolve(unit_of_work, events)

    repo_module =
      write_repo(for: [aggregate: unit_of_work.aggregate.__struct__, operation: operation])

    case Kernel.apply(repo_module, operation, [
           UnitOfWork.new(%{
             aggregate: unit_of_work.aggregate,
             schema: unit_of_work.schema
           }),
           RepoContext.for_tenant(tenant, :write)
         ]) do
      {:ok, unit_of_work} -> {:ok, unit_of_work}
      {:error, error} -> {:error, repo_error_to_error_struct(error)}
    end
  end

  @doc """
  Whether the WriteRepo that would handle this unit of work is transactional (DB).

  Checks for an adapter-level `transactional?/0` (not a Port callback — that would
  force every Mox port mock to stub it). Missing function defaults to true.
  """
  @spec transactional?(UnitOfWork.t(), [term()]) :: boolean()
  def transactional?(unit_of_work, events) do
    operation = Operation.resolve(unit_of_work, events)

    repo_module =
      write_repo(for: [aggregate: unit_of_work.aggregate.__struct__, operation: operation])

    if function_exported?(repo_module, :transactional?, 0) do
      repo_module.transactional?()
    else
      true
    end
  end

  defp repo_error_to_error_struct(%Error{} = error), do: error

  defp repo_error_to_error_struct(error) when is_atom(error),
    do: Error.new(error)

  defp repo_error_to_error_struct(error),
    do: Error.new(:repo_error, description: inspect(error))
end
