defmodule Dobro.App.Command.Commit do
  @moduledoc """
  Shared transaction and event delivery orchestration for command execution.

  Used by both inline execution and aggregate actors after a successful domain
  invocation.

  Transaction boundaries are derived from two signals:

  1. **Persist** — `PersistenceStrategy.transactional_persist?/4` (via WriteRepo
     `transactional?/0` for stateful adapters). Remote/HTTP adapters are false.
  2. **Stage** — `EventDeliveryStrategy.transactional_stage?/0`. Outbox is true;
     PubSub/None are false.

  | Persist DB? | Stage DB? | Behaviour |
  |-------------|-----------|-----------|
  | yes | yes | One transaction around persist + stage (classic outbox) |
  | no | yes | Persist outside; transaction only around stage |
  | yes/no | no | No Commit-level transaction (avoid holding a pool connection across HTTP) |
  """

  alias Dobro.App.Command.Strategy
  alias Dobro.Pipeline

  import Dobro.Pipeline

  @doc """
  Persists command side-effects and delivers events according to the resolved strategies.
  """
  @spec run(
          Strategy.t(),
          term(),
          [term()],
          term(),
          term(),
          term()
        ) :: {:ok, term(), [term()]} | {:error, term()}
  def run(%Strategy{} = strategies, unit_of_work, events, tenant, message_identity, aggregate) do
    {persistence_mod, persistence_opts} = strategies.persistence
    {delivery_mod, delivery_opts} = strategies.event_delivery
    context = %{aggregate: aggregate, tenant: tenant}

    persist_tx? =
      transactional_persist?(
        persistence_mod,
        unit_of_work,
        events,
        tenant,
        persistence_opts
      )

    stage_tx? = transactional_stage?(delivery_mod)

    cond do
      persist_tx? and stage_tx? ->
        persist_and_stage_in_transaction(
          persistence_mod,
          persistence_opts,
          delivery_mod,
          delivery_opts,
          unit_of_work,
          events,
          tenant,
          message_identity,
          context
        )

      not persist_tx? and stage_tx? ->
        persist_then_stage_in_transaction(
          persistence_mod,
          persistence_opts,
          delivery_mod,
          delivery_opts,
          unit_of_work,
          events,
          tenant,
          message_identity,
          context
        )

      true ->
        persist_and_deliver(
          persistence_mod,
          persistence_opts,
          delivery_mod,
          delivery_opts,
          unit_of_work,
          events,
          tenant,
          message_identity,
          context
        )
    end
  end

  # Local DB persist + transactional stage (outbox): atomic together.
  defp persist_and_stage_in_transaction(
         persistence_mod,
         persistence_opts,
         delivery_mod,
         delivery_opts,
         unit_of_work,
         events,
         tenant,
         message_identity,
         context
       ) do
    case Dobro.Infra.Repo.transaction(fn ->
           with {:ok, unit_of_work, events} <-
                  persistence_mod.persist(
                    unit_of_work,
                    events,
                    tenant,
                    message_identity,
                    persistence_opts
                  ),
                :ok <- delivery_mod.stage(events, context, delivery_opts) do
             {:ok, unit_of_work, events}
           end
         end) do
      {:ok, {:ok, unit_of_work, events}} ->
        deliver(delivery_mod, events, context, delivery_opts, unit_of_work)

      {:ok, {:error, error}} ->
        {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  # Non-DB persist (e.g. remote HTTP) + transactional stage: never hold a
  # checkout across the network call; stage alone runs in a transaction.
  defp persist_then_stage_in_transaction(
         persistence_mod,
         persistence_opts,
         delivery_mod,
         delivery_opts,
         unit_of_work,
         events,
         tenant,
         message_identity,
         context
       ) do
    with {:ok, unit_of_work, events} <-
           persistence_mod.persist(
             unit_of_work,
             events,
             tenant,
             message_identity,
             persistence_opts
           ),
         :ok <- stage_in_transaction(delivery_mod, events, context, delivery_opts) do
      deliver(delivery_mod, events, context, delivery_opts, unit_of_work)
    end
  end

  # No transactional stage (PubSub/None): skip Commit-level transactions so
  # remote HTTP adapters do not pin a pool connection for the whole request.
  defp persist_and_deliver(
         persistence_mod,
         persistence_opts,
         delivery_mod,
         delivery_opts,
         unit_of_work,
         events,
         tenant,
         message_identity,
         context
       ) do
    with {:ok, unit_of_work, events} <-
           persistence_mod.persist(
             unit_of_work,
             events,
             tenant,
             message_identity,
             persistence_opts
           ),
         :ok <- delivery_mod.stage(events, context, delivery_opts) do
      deliver(delivery_mod, events, context, delivery_opts, unit_of_work)
    end
  end

  defp stage_in_transaction(delivery_mod, events, context, delivery_opts) do
    case Dobro.Infra.Repo.transaction(fn ->
           delivery_mod.stage(events, context, delivery_opts)
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, error}} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  defp deliver(delivery_mod, events, context, delivery_opts, unit_of_work) do
    case delivery_mod.deliver(events, context, delivery_opts) do
      :ok -> {:ok, unit_of_work, events}
      {:error, error} -> {:error, error}
    end
  end

  defp transactional_persist?(persistence_mod, unit_of_work, events, tenant, opts) do
    if function_exported?(persistence_mod, :transactional_persist?, 4) do
      persistence_mod.transactional_persist?(unit_of_work, events, tenant, opts)
    else
      true
    end
  end

  defp transactional_stage?(delivery_mod) do
    if function_exported?(delivery_mod, :transactional_stage?, 0) do
      delivery_mod.transactional_stage?()
    else
      true
    end
  end

  @doc """
  Commits pipeline state through resolved strategies.
  """
  @spec apply_to_pipeline(Pipeline.t(), Strategy.t()) :: Pipeline.t()
  def apply_to_pipeline(%Pipeline{} = pipeline, %Strategy{} = strategies) do
    bind(pipeline, fn pipeline ->
      unit_of_work = pipeline.state.unit_of_work
      events = pipeline.state.events
      tenant = pipeline.config.tenant
      message_identity = pipeline.input.message_identity
      aggregate = unit_of_work.aggregate

      case run(strategies, unit_of_work, events, tenant, message_identity, aggregate) do
        {:ok, unit_of_work, events} ->
          put_in(pipeline.state, %{
            pipeline.state
            | unit_of_work: unit_of_work,
              events: events
          })

        {:error, error} ->
          merge_errors(pipeline, error)
      end
    end)
  end
end
