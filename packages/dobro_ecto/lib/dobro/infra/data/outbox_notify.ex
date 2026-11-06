defmodule Dobro.Infra.Data.OutboxNotify do
  @moduledoc """
  Wakes outbox pollers with `pg_notify` on the caller's connection.

  Postgres delivers the notification after the surrounding transaction commits,
  and drops it if that transaction rolls back. Pollers also refresh on a slow
  timer so a missed notification is still applied.
  """

  alias Dobro.Infra.Repo

  @domain_channel "dobro_domain_events"
  @integration_channel "dobro_integration_events"

  @spec domain_channel() :: String.t()
  def domain_channel, do: @domain_channel

  @spec integration_channel() :: String.t()
  def integration_channel, do: @integration_channel

  @spec domain(String.t()) :: :ok
  def domain(stream_name) when is_binary(stream_name), do: notify(@domain_channel, stream_name)

  @spec integration(String.t()) :: :ok
  def integration(routing_key) when is_binary(routing_key),
    do: notify(@integration_channel, routing_key)

  defp notify(channel, payload) do
    repo = Repo.repo()

    if function_exported?(repo, :query, 2) do
      _ = repo.query("SELECT pg_notify($1, $2)", [channel, payload])
    end

    :ok
  rescue
    _ -> :ok
  end
end
