defmodule Dobro.Runtime.Command.EventDeliveryStrategy.Outbox do
  @moduledoc """
  Stages domain events in a transactional outbox for async relay delivery.
  """

  @behaviour Dobro.App.Command.EventDeliveryStrategy

  alias Dobro.App.DomainEventCodec
  alias Dobro.Infra.Data.DomainEventOutboxSchema
  alias Dobro.Infra.Repo

  @impl true
  def stage([], _context, _opts), do: :ok

  def stage(events, %{aggregate: aggregate}, _opts) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
    stream_name = stream_name(aggregate)

    rows =
      Enum.map(events, fn event ->
        encoded = DomainEventCodec.encode(event)

        %{
          id: Ecto.UUID.generate(),
          stream_name: stream_name,
          event_payload: encoded,
          message_identity: encoded["message_identity"],
          inserted_at: now
        }
      end)

    case Repo.insert_all(DomainEventOutboxSchema, rows) do
      {count, _} when count == length(rows) -> :ok
      _ -> {:error, :outbox_stage_failed}
    end
  end

  @impl true
  def deliver(_events, _context, _opts), do: :ok

  @impl true
  def transactional_stage?, do: true

  @doc """
  Publishes staged outbox rows to PubSub and marks them processed.

  Called by `Dobro.Runtime.OutboxRelay`.
  """
  @spec relay(keyword()) :: :ok | {:error, term()}
  def relay(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)
    pubsub = Dobro.Config.pubsub!()

    Dobro.Infra.Repo.transaction(fn ->
      rows = fetch_batch(batch_size)

      Enum.each(rows, fn row ->
        event = DomainEventCodec.decode(row.event_payload)
        Phoenix.PubSub.broadcast(pubsub, row.stream_name, {:event, event})
      end)

      mark_processed(rows)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_batch(batch_size) do
    import Ecto.Query

    DomainEventOutboxSchema
    |> where([row], is_nil(row.processed_at))
    |> order_by([row], asc: row.inserted_at, asc: row.id)
    |> limit(^batch_size)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  defp mark_processed(rows) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
    ids = Enum.map(rows, & &1.id)

    import Ecto.Query

    DomainEventOutboxSchema
    |> where([row], row.id in ^ids)
    |> Repo.update_all(set: [processed_at: now])
  end

  defp stream_name(%_{} = aggregate), do: stream_name(aggregate.__struct__)

  defp stream_name(aggregate_module) when is_atom(aggregate_module) do
    aggregate_module.__stream_name__()
  end
end
