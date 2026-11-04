defmodule Dobro.Runtime.Persistence do
  @moduledoc false

  alias Dobro.App.Command.Strategy
  alias Dobro.App.EventStore
  alias Dobro.Error
  alias Dobro.Infra.Data.RepoContext
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  use Dobro.Spec.Consumer, ports: [write_repo: Dobro.Infra.Data.WriteRepo.Port]

  def load(aggregate_module, load_fn, identity, tenant, opts \\ []) do
    strategy =
      Keyword.get(opts, :persistence_strategy) || persistence_strategy(aggregate_module)

    load_mode = Keyword.get(opts, :load, :required)

    case strategy do
      :event_sourced ->
        load_from_event_store(aggregate_module, identity, tenant, load_mode)

      _ ->
        load_from_write_repo(aggregate_module, load_fn, identity, tenant, load_mode)
    end
  end

  defp load_from_event_store(_aggregate_module, nil, _tenant, _load_mode), do: {:ok, nil}

  defp load_from_event_store(aggregate_module, identity, tenant, load_mode) do
    stream_name = EventStore.stream_id(aggregate_module, tenant, identity)

    case EventStore.replay(aggregate_module, stream_name) do
      {:ok, nil} ->
        maybe_optional_miss(load_mode)

      {:ok, aggregate} ->
        {:ok, UnitOfWork.new(%{aggregate: aggregate, schema: nil})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp load_from_write_repo(aggregate_module, load_fn, identity, tenant, load_mode) do
    repo_module = write_repo(for: [aggregate: aggregate_module, operation: load_fn])
    context = RepoContext.for_tenant(tenant, :write)

    load_fn_result =
      if is_nil(identity) do
        repo_module |> apply(load_fn, [context])
      else
        repo_module |> apply(load_fn, [identity, context])
      end

    case load_fn_result do
      {:ok, nil} ->
        maybe_optional_miss(load_mode)

      {:ok, unit_of_work} ->
        {:ok, unit_of_work}

      {:error, %Error{reason: :not_found}} ->
        maybe_optional_miss(load_mode)

      {:error, error} ->
        {:error, repo_error_to_error_struct(error)}

      error ->
        {:error, repo_error_to_error_struct(error)}
    end
  end

  defp maybe_optional_miss(:optional) do
    {:ok, UnitOfWork.new(%{aggregate: nil, schema: nil})}
  end

  defp maybe_optional_miss(_required) do
    {:error, Error.new(:not_found)}
  end

  defp persistence_strategy(aggregate_module) do
    if function_exported?(aggregate_module, :__persistence_strategy__, 0) do
      aggregate_module.__persistence_strategy__() ||
        Strategy.lookup(:persistence_strategy, [])
    else
      Strategy.lookup(:persistence_strategy, [])
    end
  end

  defp repo_error_to_error_struct(%Error{} = error), do: error

  defp repo_error_to_error_struct(error) when is_atom(error),
    do: Error.new(error)

  defp repo_error_to_error_struct(error),
    do: Error.new(:repo_error, description: inspect(error))
end
