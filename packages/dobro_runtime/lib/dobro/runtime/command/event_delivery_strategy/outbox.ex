defmodule Dobro.Runtime.Command.EventDeliveryStrategy.Outbox do
  @moduledoc """
  Stages domain events in a transactional outbox for async relay delivery.

  Storage operations live in `Dobro.Infra.Data.Outbox`. This module implements
  the delivery strategy and PubSub relay: claim → broadcast → mark processed.
  """

  @behaviour Dobro.App.Command.EventDeliveryStrategy

  alias Dobro.App.DomainEventCodec
  alias Dobro.Infra.Data.Outbox

  @impl true
  def stage([], _context, _opts), do: :ok

  def stage(events, %{aggregate: aggregate}, _opts) do
    Outbox.insert(stream_name(aggregate), events)
  end

  @impl true
  def deliver(_events, _context, _opts), do: :ok

  @impl true
  def transactional_stage?, do: true

  @doc """
  Claims staged outbox rows, publishes to PubSub outside the DB transaction,
  then marks them processed.

  At-least-once: if the process crashes after publish but before mark, a stale
  claim timeout allows another relay to republish. Consumers must be idempotent.

  Called by `Dobro.Runtime.OutboxRelay`.
  """
  @spec relay(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def relay(opts \\ []) do
    pubsub = Dobro.Config.pubsub!()
    claim_opts = Keyword.take(opts, [:batch_size, :claim_timeout_ms])

    case Outbox.claim(claim_opts) do
      {:ok, []} ->
        {:ok, 0}

      {:ok, rows} ->
        case publish_all(rows, pubsub) do
          :ok ->
            case Outbox.mark_processed(rows) do
              :ok -> {:ok, length(rows)}
              {:error, _reason} = error -> error
            end

          {:error, _reason} = error ->
            _ = Outbox.release(rows)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp publish_all(rows, pubsub) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      event = DomainEventCodec.decode(row.event_payload)

      case Phoenix.PubSub.broadcast(pubsub, row.stream_name, {:event, event}) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stream_name(%_{} = aggregate), do: stream_name(aggregate.__struct__)

  defp stream_name(aggregate_module) when is_atom(aggregate_module) do
    aggregate_module.__stream_name__()
  end
end
