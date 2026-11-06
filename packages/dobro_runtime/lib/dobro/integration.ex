defmodule Dobro.Integration do
  @moduledoc """
  Publish integration events and inspect the integration catalog.

  `publish/1` inserts an outbox row on the current connection and raises when
  no transaction is open. Subscribers do not call this module to receive events.
  """

  alias Dobro.Infra.Data.IntegrationOutbox
  alias Dobro.Infra.Repo
  alias Dobro.Ports.EventHandler

  @doc """
  Stages an integration event. Required keys: `:topic`, `:event_name`.

  Optional: `:payload`, `:id`, `:causation_id`, `:partition_key`, `:subject_type`,
  `:subject_id`, `:occurred_at`.
  """
  @spec publish(map()) :: :ok
  def publish(event) when is_map(event) do
    unless Repo.in_transaction?() do
      raise "Dobro.Integration.publish/1 must run inside a transaction"
    end

    case IntegrationOutbox.insert(event) do
      {:ok, _position} -> :ok
      {:error, reason} -> raise "integration publish failed: #{inspect(reason)}"
    end
  end

  @doc """
  Every published integration event known to registered publishers.
  """
  @spec catalog() :: [map()]
  def catalog do
    EventHandler.all()
    |> Enum.flat_map(fn handler ->
      Code.ensure_loaded(handler)

      if function_exported?(handler, :__integration_events__, 0) do
        handler.__integration_events__()
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1.routing_key)
    |> Enum.sort_by(& &1.routing_key)
  end

  @doc """
  Topic prefixes for handlers that subscribe to every event from a BC.

  Each entry is `topic.#`.
  """
  @spec prefixes() :: [String.t()]
  def prefixes do
    catalog()
    |> Enum.map(& &1.topic)
    |> Enum.uniq()
    |> Enum.map(&(&1 <> ".#"))
    |> Enum.sort()
  end
end
