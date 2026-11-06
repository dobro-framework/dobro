defmodule Dobro.Runtime.DomainEventPoller do
  @moduledoc """
  Delivers one domain-event stream to one handler from `shared.domain_event_outbox`.

  A committed insert notifies this poller. The timer is only a refresh for a
  notification that was missed, including rows written while this process was
  down. The cursor is `(inserted_at, id)`. A handler that has not run starts at
  the beginning of the stream. A row is deleted only after every handler cursor
  for that stream has passed it.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Dobro.App.DomainEventCodec
  alias Dobro.Infra.Data.DomainEventOutboxSchema
  alias Dobro.Infra.Data.IntegrationOutbox
  alias Dobro.Infra.Repo
  alias Dobro.Ports.EventHandler
  alias Dobro.Runtime.ActorLock
  alias Dobro.Runtime.Integration.Delivery

  @refresh_interval_ms 60_000
  @batch 20
  @drain_loops 50

  def start_link(opts) do
    handler = Keyword.fetch!(opts, :handler)
    stream = Keyword.fetch!(opts, :stream)
    GenServer.start_link(__MODULE__, opts, name: via(handler, stream))
  end

  def via(handler, stream) do
    Dobro.Runtime.ActorRegistry.via({:domain_poller, handler, stream})
  end

  @doc """
  Processes pending events on every domain poller before returning.

  Projection waits call this so a committed outbox row is applied before the
  caller starts waiting for `projection_updated`.
  """
  def drain_all do
    case Process.whereis(Dobro.Runtime.EventHandlerSupervisor) do
      nil ->
        :ok

      _pid ->
        for {_, pid, _, _} <- Supervisor.which_children(Dobro.Runtime.EventHandlerSupervisor),
            is_pid(pid) do
          try do
            GenServer.call(pid, :drain, 15_000)
          catch
            :exit, _ -> :ok
          end
        end

        :ok
    end
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
    poll(state)
  rescue
    error ->
      Logger.warning("domain poller failed: #{Exception.message(error)}")
      :error
  catch
    kind, reason ->
      Logger.warning("domain poller failed: #{inspect({kind, reason})}")
      :error
  end

  defp poll(%{handler: handler, stream: stream}) do
    key = {:domain_poller, handler, stream}

    case ActorLock.try_acquire(key, self()) do
      :ok ->
        try do
          deliver(handler, stream)
        after
          ActorLock.release(key)
        end

      _ ->
        :idle
    end
  end

  defp deliver(handler, stream) do
    Repo.transaction(fn ->
      IntegrationOutbox.ensure_subscription(handler, "domain", stream, nil)
    end)

    case IntegrationOutbox.get_subscription(to_string(handler), "domain", stream) do
      nil ->
        :idle

      subscription ->
        case next_rows(stream, subscription) do
          [] -> :idle
          rows -> walk(handler, stream, rows)
        end
    end
  end

  defp next_rows(stream, subscription) do
    base =
      DomainEventOutboxSchema
      |> where([row], row.stream_name == ^stream)
      |> order_by([row], asc: row.inserted_at, asc: row.id)
      |> limit(@batch)

    base =
      case subscription.last_inserted_at do
        nil ->
          base

        at ->
          id = subscription.last_event_id

          where(
            base,
            [row],
            row.inserted_at > ^at or (row.inserted_at == ^at and row.id > ^id)
          )
      end

    Repo.all(base)
  end

  defp walk(handler, stream, [row | _rest]) do
    event = DomainEventCodec.decode(row.event_payload)

    result =
      Delivery.run(handler, event,
        transaction: &transaction/2,
        advance: fn ->
          IntegrationOutbox.advance_domain(handler, stream, row.inserted_at, row.id)
        end,
        record_failure: fn reason ->
          IntegrationOutbox.record_failure(handler, "domain", stream, reason)
        end,
        dead_letter: fn event, reason ->
          Dobro.Infra.Data.IntegrationOutbox.dead_letter(handler, stream, %{
            id: row.id,
            payload: Map.from_struct(event)
          }, reason)
        end
      )

    if result == :ok or match?({:dead_letter, _}, result) do
      purge_passed(stream)
      :ok
    else
      :error
    end
  end

  defp purge_passed(stream) do
    handlers = handlers_for(stream)

    cursors =
      Enum.map(handlers, fn handler ->
        IntegrationOutbox.get_subscription(to_string(handler), "domain", stream)
      end)

    if Enum.all?(cursors, &match?(%{last_inserted_at: at} when not is_nil(at), &1)) do
      {min_at, min_id} =
        cursors
        |> Enum.map(&{&1.last_inserted_at, &1.last_event_id})
        |> Enum.min()

      DomainEventOutboxSchema
      |> where([row], row.stream_name == ^stream)
      |> where(
        [row],
        row.inserted_at < ^min_at or (row.inserted_at == ^min_at and row.id <= ^min_id)
      )
      |> Repo.delete_all()
    end

    :ok
  end

  defp handlers_for(stream) do
    EventHandler.all()
    |> Enum.filter(fn handler -> stream in streams(handler) end)
  end

  @doc false
  def streams(handler) do
    Code.ensure_loaded(handler)

    cond do
      function_exported?(handler, :__stream_names__, 0) -> handler.__stream_names__()
      function_exported?(handler, :__stream_name__, 0) -> [handler.__stream_name__()]
      true -> []
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
      Application.get_env(:dobro_runtime, :domain_poll_interval_ms, @refresh_interval_ms)

    %{state | timer: Process.send_after(self(), :poll, interval)}
  end
end
