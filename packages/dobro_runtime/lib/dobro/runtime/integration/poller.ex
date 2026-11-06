defmodule Dobro.Runtime.Integration.Poller do
  @moduledoc """
  Drains one integration pattern subscription.

  A committed insert notifies every poller whose pattern matches the routing
  key. The timer is only a refresh for a notification that was missed. Non-matching
  rows advance the cursor without calling `handle/1`. A match is delivered and
  the poller stops until that delivery finishes, so later rows on the pattern
  wait. A pattern with no cursor starts at the current end of the log.
  """

  use GenServer

  require Logger

  alias Dobro.Infra.Data.IntegrationOutbox
  alias Dobro.Infra.Repo
  alias Dobro.Integration.Pattern
  alias Dobro.Runtime.ActorLock
  alias Dobro.Runtime.Integration.Delivery

  @refresh_interval_ms 60_000
  @batch 50
  @drain_loops 50

  def start_link(opts) do
    handler = Keyword.fetch!(opts, :handler)
    pattern = Keyword.fetch!(opts, :pattern)
    GenServer.start_link(__MODULE__, opts, name: via(handler, pattern))
  end

  def via(handler, pattern) do
    Dobro.Runtime.ActorRegistry.via({:integration_poller, handler, pattern})
  end

  @impl GenServer
  def init(opts) do
    state = opts |> Map.new() |> Map.put(:timer, nil)
    {:ok, schedule(state)}
  end

  @impl GenServer
  def handle_info(message, state) when message in [:poll, :notify] do
    flush_notify()

    if drain(state, @drain_loops) == :more, do: send(self(), :notify)

    state = if message == :poll, do: schedule(state), else: state
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:drain, _from, state) do
    {:reply, drain(state, 50), state}
  end

  defp drain(_state, 0), do: :more

  defp drain(state, remaining) do
    case safe_poll(state) do
      :idle -> :ok
      :ok -> drain(state, remaining - 1)
      _ -> :ok
    end
  end

  defp flush_notify do
    receive do
      :notify -> flush_notify()
    after
      0 -> :ok
    end
  end

  defp safe_poll(state) do
    maybe_poll(state)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp maybe_poll(%{handler: handler, pattern: pattern} = state) do
    key = {:integration_poller, handler, pattern}

    case ActorLock.try_acquire(key, self()) do
      :ok ->
        try do
          poll(state)
        after
          ActorLock.release(key)
        end

      {:error, :locked} ->
        :idle

      {:error, reason} ->
        Logger.warning("integration poller lock failed: #{inspect(reason)}")
        :idle
    end
  end

  defp poll(%{handler: handler, pattern: pattern}) do
    subscription =
      Repo.transaction(fn ->
        IntegrationOutbox.ensure_subscription(handler, "integration", pattern, nil)
      end)

    case subscription do
      {:ok, %{last_position: nil}} ->
        Repo.transaction(fn ->
          IntegrationOutbox.advance(handler, "integration", pattern, IntegrationOutbox.max_position())
        end)

        :idle

      {:ok, sub} ->
        deliver_available(handler, pattern, sub.last_position || 0)

      {:error, reason} ->
        Logger.warning("integration subscription failed: #{inspect(reason)}")
        :error
    end
  end

  defp deliver_available(handler, pattern, position) do
    rows = IntegrationOutbox.next_after(position, @batch)
    walk(handler, pattern, rows)
  end

  defp walk(_handler, _pattern, []), do: :idle

  defp walk(handler, pattern, [row | rest]) do
    if Pattern.match?(pattern, row.routing_key) do
      event = %{
        id: row.id,
        topic: row.topic,
        event_name: row.event_name,
        routing_key: row.routing_key,
        payload: row.payload,
        causation_id: row.causation_id,
        partition_key: row.partition_key,
        subject_type: row.subject_type,
        subject_id: row.subject_id,
        occurred_at: row.occurred_at,
        position: row.position
      }

      result =
        Delivery.run(handler, event,
          transaction: &transaction/2,
          advance: fn -> IntegrationOutbox.advance(handler, "integration", pattern, row.position) end,
          record_failure: fn reason ->
            IntegrationOutbox.record_failure(handler, "integration", pattern, reason)
          end,
          dead_letter: fn event, reason ->
            IntegrationOutbox.dead_letter(handler, pattern, event, reason)
          end
        )

      if result == :ok or match?({:dead_letter, _}, result), do: :ok, else: :error
    else
      Repo.transaction(fn ->
        IntegrationOutbox.advance(handler, "integration", pattern, row.position)
      end)

      walk(handler, pattern, rest)
    end
  end

  defp transaction(fun, opts) do
    Repo.transaction(
      fn ->
        case fun.() do
          :ok -> :ok
          {:ok, effects} -> {:ok, effects}
          {:error, reason} -> Repo.repo().rollback(reason)
        end
      end,
      opts
    )
  end

  defp schedule(state) do
    if is_reference(state[:timer]), do: Process.cancel_timer(state.timer)

    interval =
      Application.get_env(:dobro_runtime, :integration_poll_interval_ms, @refresh_interval_ms)

    %{state | timer: Process.send_after(self(), :poll, interval)}
  end
end
