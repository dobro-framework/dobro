defmodule Dobro.Infra.Data.Outbox do
  @moduledoc """
  Table operations for the transactional domain-event outbox.

  Staging (`insert/2`) runs inside the command transaction. Relay claims a batch
  with `FOR UPDATE SKIP LOCKED`, publishes outside the transaction, then
  `mark_processed/1`. Failed publishes should `release/1` so rows can be retried.
  Stale claims older than `claim_timeout_ms` are reclaimable.
  """

  import Ecto.Query

  alias Dobro.App.DomainEventCodec
  alias Dobro.Infra.Data.DomainEventOutboxSchema
  alias Dobro.Infra.Repo

  @default_batch_size 100
  @default_claim_timeout_ms :timer.minutes(5)

  @doc """
  Encodes and inserts outbox rows for a stream.

  Must be called inside the same DB transaction as the business write.
  """
  @spec insert(String.t(), [struct()]) :: :ok | {:error, term()}
  def insert(_stream_name, []), do: :ok

  def insert(stream_name, events) when is_binary(stream_name) and is_list(events) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

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

  @doc """
  Claims a batch of unprocessed rows for relay.

  Sets `claimed_at` in a short transaction so concurrent relays skip these rows.
  Rows with a stale `claimed_at` (older than `claim_timeout_ms`) are eligible again.
  """
  @spec claim(keyword()) :: {:ok, [struct()]} | {:error, term()}
  def claim(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    claim_timeout_ms = Keyword.get(opts, :claim_timeout_ms, @default_claim_timeout_ms)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
    stale_before = NaiveDateTime.add(now, -claim_timeout_ms, :millisecond)

    Repo.transaction(fn ->
      rows =
        DomainEventOutboxSchema
        |> where([row], is_nil(row.processed_at))
        |> where([row], is_nil(row.claimed_at) or row.claimed_at < ^stale_before)
        |> order_by([row], asc: row.inserted_at, asc: row.id)
        |> limit(^batch_size)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()

      ids = Enum.map(rows, & &1.id)

      if ids != [] do
        DomainEventOutboxSchema
        |> where([row], row.id in ^ids)
        |> Repo.update_all(set: [claimed_at: now])
      end

      Enum.map(rows, fn row -> %{row | claimed_at: now} end)
    end)
  end

  @doc "Marks claimed rows as processed after successful publish."
  @spec mark_processed([struct()] | [term()]) :: :ok | {:error, term()}
  def mark_processed([]), do: :ok

  def mark_processed(rows_or_ids) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
    ids = normalize_ids(rows_or_ids)

    {_, _} =
      DomainEventOutboxSchema
      |> where([row], row.id in ^ids)
      |> Repo.update_all(set: [processed_at: now])

    :ok
  rescue
    error -> {:error, error}
  end

  @doc "Clears `claimed_at` so rows can be retried after a publish failure."
  @spec release([struct()] | [term()]) :: :ok | {:error, term()}
  def release([]), do: :ok

  def release(rows_or_ids) do
    ids = normalize_ids(rows_or_ids)

    {_, _} =
      DomainEventOutboxSchema
      |> where([row], row.id in ^ids and is_nil(row.processed_at))
      |> Repo.update_all(set: [claimed_at: nil])

    :ok
  rescue
    error -> {:error, error}
  end

  @doc """
  Deletes rows whose `processed_at` is at or before `older_than`.

  Returns `{:ok, deleted_count}`.
  """
  @spec purge(NaiveDateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def purge(%NaiveDateTime{} = older_than) do
    {count, _} =
      DomainEventOutboxSchema
      |> where([row], not is_nil(row.processed_at) and row.processed_at <= ^older_than)
      |> Repo.delete_all()

    {:ok, count}
  rescue
    error -> {:error, error}
  end

  defp normalize_ids([%{id: _} | _] = rows), do: Enum.map(rows, & &1.id)
  defp normalize_ids(ids) when is_list(ids), do: ids
end
