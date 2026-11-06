defmodule Dobro.Infra.Data.IntegrationOutbox do
  @moduledoc """
  Table operations for the integration outbox and its subscription cursors.
  """

  import Ecto.Query

  alias Dobro.Infra.Data.IntegrationDeadLetterSchema
  alias Dobro.Infra.Data.IntegrationEventOutboxSchema
  alias Dobro.Infra.Data.IntegrationSubscriptionSchema
  alias Dobro.Infra.Data.OutboxNotify
  alias Dobro.Infra.Repo
  alias Dobro.Integration.Pattern

  @spec insert(map()) :: {:ok, integer()} | {:error, term()}
  def insert(event) when is_map(event) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    id = Map.get(event, :id) || Ecto.UUID.generate()
    topic = Map.fetch!(event, :topic)
    event_name = Map.fetch!(event, :event_name)

    row = %{
      id: id,
      topic: topic,
      event_name: event_name,
      routing_key: Pattern.routing_key(topic, event_name),
      payload: Map.get(event, :payload) || %{},
      causation_id: Map.get(event, :causation_id),
      partition_key: event |> Map.get(:partition_key) |> stringify(),
      subject_type: Map.get(event, :subject_type),
      subject_id: event |> Map.get(:subject_id) |> stringify(),
      occurred_at: usec(Map.get(event, :occurred_at) || now),
      inserted_at: now
    }

    case Repo.insert_all(IntegrationEventOutboxSchema, [row], returning: [:position]) do
      {1, [%{position: position}]} ->
        OutboxNotify.integration(row.routing_key)
        {:ok, position}

      {1, _} ->
        OutboxNotify.integration(row.routing_key)
        {:ok, 0}

      _ ->
        {:error, :integration_outbox_insert_failed}
    end
  end

  @spec max_position() :: integer()
  def max_position do
    IntegrationEventOutboxSchema
    |> select([row], coalesce(max(row.position), 0))
    |> Repo.one()
  end

  @spec next_after(integer(), pos_integer()) :: [IntegrationEventOutboxSchema.t()]
  def next_after(position, limit) do
    IntegrationEventOutboxSchema
    |> where([row], row.position > ^position)
    |> order_by([row], asc: row.position)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec ensure_subscription(module(), String.t(), String.t(), integer() | nil) ::
          IntegrationSubscriptionSchema.t()
  def ensure_subscription(handler, log, pattern, initial_position) do
    handler_module = handler |> to_string()

    case get_subscription(handler_module, log, pattern) do
      nil ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        row = %{
          handler_module: handler_module,
          log: log,
          pattern: pattern,
          last_position: initial_position,
          failure_count: 0,
          inserted_at: now,
          updated_at: now
        }

        Repo.insert_all(IntegrationSubscriptionSchema, [row])
        get_subscription(handler_module, log, pattern)

      subscription ->
        subscription
    end
  end

  @spec get_subscription(String.t(), String.t(), String.t()) ::
          IntegrationSubscriptionSchema.t() | nil
  def get_subscription(handler_module, log, pattern) do
    Repo.get_by(IntegrationSubscriptionSchema,
      handler_module: handler_module,
      log: log,
      pattern: pattern
    )
  end

  @spec advance(module(), String.t(), String.t(), integer()) :: :ok
  def advance(handler, log, pattern, position) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    handler_module = to_string(handler)

    IntegrationSubscriptionSchema
    |> where(
      [row],
      row.handler_module == ^handler_module and row.log == ^log and row.pattern == ^pattern
    )
    |> Repo.update_all(set: [last_position: position, failure_count: 0, last_error: nil, updated_at: now])

    :ok
  end

  @spec record_failure(module(), String.t(), String.t(), term()) :: integer()
  def record_failure(handler, log, pattern, error) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    handler_module = to_string(handler)
    message = error |> inspect() |> String.slice(0, 2000)

    {_, _} =
      IntegrationSubscriptionSchema
      |> where(
        [row],
        row.handler_module == ^handler_module and row.log == ^log and row.pattern == ^pattern
      )
      |> Repo.update_all(inc: [failure_count: 1], set: [last_error: message, updated_at: now])

    case get_subscription(handler_module, log, pattern) do
      %{failure_count: count} -> count
      _ -> 1
    end
  end

  @spec dead_letter(module(), String.t(), map(), term()) :: :ok
  def dead_letter(handler, pattern, event, error) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(IntegrationDeadLetterSchema, [
      %{
        id: Ecto.UUID.generate(),
        handler_module: to_string(handler),
        pattern: pattern,
        log: "integration",
        event_id: Map.get(event, :id),
        payload: Map.get(event, :payload) || event,
        last_error: error |> inspect() |> String.slice(0, 2000),
        inserted_at: now
      }
    ])

    :ok
  end

  @spec advance_domain(module(), String.t(), NaiveDateTime.t(), integer()) :: :ok
  def advance_domain(handler, stream_name, inserted_at, event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    handler_module = to_string(handler)

    IntegrationSubscriptionSchema
    |> where(
      [row],
      row.handler_module == ^handler_module and row.log == "domain" and row.pattern == ^stream_name
    )
    |> Repo.update_all(
      set: [
        last_inserted_at: inserted_at,
        last_event_id: event_id,
        failure_count: 0,
        last_error: nil,
        updated_at: now
      ]
    )

    :ok
  end

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp usec(value), do: cast_occurred_at!(value)

  @doc false
  def cast_occurred_at!(%DateTime{} = value) do
    %{value | microsecond: {elem(value.microsecond, 0), 6}}
  end

  def cast_occurred_at!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        cast_occurred_at!(dt)

      {:error, reason} ->
        raise ArgumentError, "invalid occurred_at #{inspect(value)}: #{inspect(reason)}"
    end
  end

  def cast_occurred_at!(other) do
    raise ArgumentError, "invalid occurred_at: #{inspect(other)}"
  end
end
