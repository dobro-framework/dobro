defmodule Dobro.Runtime.OutboxRelay do
  @moduledoc """
  Polls the domain event outbox and publishes staged events to PubSub.

  Options (merged from `config :dobro_runtime, :outbox_relay` and `start_link/1`):

  - `:batch_size` — rows per claim (default `100`)
  - `:poll_interval_ms` — relay poll interval (default `1_000`)
  - `:claim_timeout_ms` — stale claim reclaim window (default 5 minutes)
  - `:purge_after_ms` — when set, delete processed rows older than this age
  - `:purge_interval_ms` — how often to run purge when enabled (default `60_000`)
  """

  use GenServer

  require Logger

  alias Dobro.Infra.Data.Outbox
  alias Dobro.Runtime.Command.EventDeliveryStrategy.Outbox, as: OutboxDelivery

  @default_poll_interval_ms 1_000
  @default_purge_interval_ms 60_000
  @default_claim_timeout_ms :timer.minutes(5)

  def start_link(opts \\ []) do
    opts = merge_opts(opts)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    schedule_poll(opts)

    if Keyword.get(opts, :purge_after_ms) do
      schedule_purge(opts)
    end

    {:ok, opts}
  end

  @impl GenServer
  def handle_info(:poll, opts) do
    relay_opts = Keyword.take(opts, [:batch_size, :claim_timeout_ms])

    case OutboxDelivery.relay(relay_opts) do
      {:ok, count} ->
        :telemetry.execute([:dobro, :outbox, :relay], %{count: count}, %{result: :ok})

      {:error, reason} ->
        Logger.warning("outbox relay failed: #{inspect(reason)}")
        :telemetry.execute([:dobro, :outbox, :relay], %{count: 0}, %{result: :error})
    end

    schedule_poll(opts)
    {:noreply, opts}
  end

  def handle_info(:purge, opts) do
    case run_purge(opts) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("outbox purged #{count} processed rows")
        :telemetry.execute([:dobro, :outbox, :purge], %{count: count}, %{result: :ok})

      {:error, reason} ->
        Logger.warning("outbox purge failed: #{inspect(reason)}")
        :telemetry.execute([:dobro, :outbox, :purge], %{count: 0}, %{result: :error})
    end

    schedule_purge(opts)
    {:noreply, opts}
  end

  defp run_purge(opts) do
    case Keyword.get(opts, :purge_after_ms) do
      nil ->
        {:ok, 0}

      purge_after_ms when is_integer(purge_after_ms) and purge_after_ms > 0 ->
        older_than =
          NaiveDateTime.utc_now()
          |> NaiveDateTime.add(-purge_after_ms, :millisecond)
          |> NaiveDateTime.truncate(:microsecond)

        Outbox.purge(older_than)

      other ->
        {:error, {:invalid_purge_after_ms, other}}
    end
  end

  defp schedule_poll(opts) do
    interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    Process.send_after(self(), :poll, interval)
  end

  defp schedule_purge(opts) do
    interval = Keyword.get(opts, :purge_interval_ms, @default_purge_interval_ms)
    Process.send_after(self(), :purge, interval)
  end

  defp merge_opts(opts) do
    config = Application.get_env(:dobro_runtime, :outbox_relay, [])

    defaults = [
      batch_size: 100,
      poll_interval_ms: @default_poll_interval_ms,
      claim_timeout_ms: @default_claim_timeout_ms,
      purge_after_ms: nil,
      purge_interval_ms: @default_purge_interval_ms
    ]

    defaults
    |> Keyword.merge(Keyword.take(config, Keyword.keys(defaults)))
    |> Keyword.merge(Keyword.take(opts, Keyword.keys(defaults) ++ [:name]))
  end
end
