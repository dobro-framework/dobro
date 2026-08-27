defmodule Dobro.App.EventStore do
  @moduledoc """
  Append-only domain event store backed by PostgreSQL.

  Configure the schema prefix via `config :dobro_ecto, :event_store_schema, "event_store"`.
  """

  import Ecto.Query

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.DomainEventCodec
  alias Dobro.Infra.Data.DomainEventRecordSchema
  alias Dobro.Infra.Repo
  alias Dobro.Tenant

  @doc """
  Builds a stream name for an aggregate instance.

  Normalizes the tenant first so id-only and identifier-only access paths share
  one stream partition.
  """
  @spec stream_id(module(), term(), term()) :: String.t()
  def stream_id(aggregate_module, tenant, identity) do
    [
      aggregate_module.__stream_name__(),
      tenant_partition(tenant),
      identity_identifier(identity)
    ]
    |> Enum.join("/")
  end

  @doc """
  Appends enriched domain events to a stream inside the current transaction.
  """
  @spec append(String.t(), [struct()]) :: :ok | {:error, term()}
  def append(stream_name, events) when is_list(events) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)
    starting_number = next_event_number(stream_name)

    rows =
      events
      |> Enum.with_index(starting_number)
      |> Enum.map(fn {event, event_number} ->
        encoded = DomainEventCodec.encode(event)

        %{
          id: Ecto.UUID.generate(),
          stream_name: stream_name,
          event_number: event_number,
          event_type: encoded["event_type"],
          event_payload: encoded,
          message_identity: encoded["message_identity"],
          version: encoded["version"],
          inserted_at: now
        }
      end)

    case Repo.insert_all(DomainEventRecordSchema, rows) do
      {count, _} when count == length(rows) -> :ok
      _ -> {:error, :event_store_append_failed}
    end
  end

  @doc """
  Reads all events for a stream ordered by event number.
  """
  @spec read_stream(String.t()) :: [struct()]
  def read_stream(stream_name) do
    DomainEventRecordSchema
    |> where([event], event.stream_name == ^stream_name)
    |> order_by([event], asc: event.event_number)
    |> Repo.all()
    |> Enum.map(&decode_record/1)
  end

  @doc """
  Replays a stream into aggregate state.
  """
  @spec replay(module(), String.t()) :: {:ok, struct() | nil} | {:error, term()}
  def replay(aggregate_module, stream_name) do
    events = read_stream(stream_name)

    if events == [] do
      {:ok, nil}
    else
      events
      |> Enum.reduce_while({:ok, struct(aggregate_module, version: 0)}, fn event, {:ok, aggregate} ->
        case aggregate_module.apply(aggregate, event) do
          {:ok, next_aggregate} -> {:cont, {:ok, next_aggregate}}
          {:error, error} -> {:halt, {:error, error}}
          other -> {:halt, {:error, other}}
        end
      end)
    end
  end

  defp decode_record(%DomainEventRecordSchema{event_payload: payload}) do
    DomainEventCodec.decode(payload)
  end

  defp next_event_number(stream_name) do
    query =
      from event in DomainEventRecordSchema,
        where: event.stream_name == ^stream_name,
        select: max(event.event_number)

    case Repo.one(query) do
      nil -> 1
      number -> number + 1
    end
  end

  defp tenant_partition(nil), do: Tenant.partition_key!(nil)

  defp tenant_partition(%TenantContext{} = tenant), do: Tenant.partition_key!(tenant)

  defp tenant_partition(tenant) when is_map(tenant) do
    Tenant.partition_key!(TenantContext.new(tenant))
  end

  defp tenant_partition(tenant), do: to_string(tenant)

  defp identity_identifier(nil), do: "none"

  defp identity_identifier(identity) when is_map(identity) do
    identity
    |> Enum.sort()
    |> Enum.map_join(":", fn {key, value} -> "#{key}:#{value}" end)
  end

  defp identity_identifier(identity), do: to_string(identity)
end
