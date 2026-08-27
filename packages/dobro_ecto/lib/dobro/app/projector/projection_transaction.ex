defmodule Dobro.App.Projector.ProjectionTransaction do
  @moduledoc """
  Runs projection updates inside a database transaction.

  Tracks the last seen event number, then invokes the projector module. Treats
  duplicate events as idempotent successes.
  """

  alias Dobro.App.Projector.ProjectionVersion

  @doc """
  Projects `event` with `module`, recording version metadata in `projection_version`.

  Returns `{:ok, :ok}` on success or `{:error, reason}` when projection fails.
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

  defp track_projection_version(projection_version, update_projection_version, prefix) do
    Dobro.Infra.Repo.insert(projection_version,
      prefix: prefix,
      on_conflict: update_projection_version,
      conflict_target: [:projection_name, :stream_name]
    )
  rescue
    _exception in Ecto.StaleEntryError ->
      {:error, :already_seen_event}

    exception ->
      reraise exception, __STACKTRACE__
  end

  defp project_event(module, event) do
    case module.project(event) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
      :error -> {:error, :projection_failed}
      other -> {:error, {:unexpected_projection_result, other}}
    end
  end
end
