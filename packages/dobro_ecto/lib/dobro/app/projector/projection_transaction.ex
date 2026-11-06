defmodule Dobro.App.Projector.ProjectionTransaction do
  @moduledoc """
  Runs projection updates inside a database transaction.

  Tracks the last seen event number, then invokes the projector module. Treats
  duplicate events as idempotent successes.

  `project/1` may return deferred after-commit effects:

      :ok
      {:ok, after_commit: fun | [fun]}
      {:error, reason}
      [result, ...]   # several of the above; effects are merged, first error wins

  Those effects are returned to the caller and must be run only after the
  outer delivery transaction has committed.
  """

  alias Dobro.App.Projector.ProjectionVersion

  @doc """
  Projects `event` with `module`, recording version metadata in `projection_version`.

  Returns `{:ok, {:ok, effects}}` on success, `{:ok, {:error, :already_seen_event}}`
  when the event was already projected, or `{:error, reason}` when the transaction
  fails.
  """
  def run(
        module,
        event,
        %ProjectionVersion{} = projection_version,
        update_projection_version,
        prefix,
        opts
      ) do
    Dobro.Infra.Repo.transaction(
      fn ->
        with {:ok, _} <-
               track_projection_version(projection_version, update_projection_version, prefix) do
          project_event(module, event)
        end
      end,
      opts
    )
  end

  @doc false
  def normalize_project_result(results) when is_list(results) do
    if Keyword.keyword?(results) do
      {:error, {:unexpected_projection_result, results}}
    else
      merge_project_results(results)
    end
  end

  def normalize_project_result(result), do: normalize_one(result)

  defp track_projection_version(projection_version, update_projection_version, prefix) do
    Dobro.Infra.Repo.insert(projection_version,
      prefix: prefix,
      on_conflict: update_projection_version,
      conflict_target: [:projection_name, :stream_name, :partition_key],
      # When the conflict UPDATE matches no rows (version already seen), raise
      # so we treat the event as idempotent rather than re-projecting.
      stale_error_field: :last_seen_event_number
    )
  rescue
    _exception in Ecto.StaleEntryError ->
      {:error, :already_seen_event}

    exception ->
      reraise exception, __STACKTRACE__
  end

  defp project_event(module, event) do
    event
    |> module.project()
    |> normalize_project_result()
  end

  defp merge_project_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case normalize_one(result) do
        {:ok, effects} -> {:cont, {:ok, acc ++ effects}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_one(:ok), do: {:ok, []}

  defp normalize_one({:ok, after_commit: effects}), do: {:ok, List.wrap(effects)}

  defp normalize_one({:ok, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts |> Keyword.get(:after_commit, []) |> List.wrap()}
    else
      {:ok, []}
    end
  end

  defp normalize_one({:ok, _}), do: {:ok, []}
  defp normalize_one({:error, _} = error), do: error
  defp normalize_one(:error), do: {:error, :projection_failed}

  defp normalize_one(other),
    do: {:error, {:unexpected_projection_result, other}}
end
