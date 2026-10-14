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

  | Persist DB? | Stage DB? | `after_persist` | Behaviour |
  |-------------|-----------|-----------------|-----------|
  | yes | yes | any | One transaction around persist + after_persist + stage |
  | yes | no | set | One transaction around persist + after_persist; stage/deliver outside |
  | yes | no | nil | No Commit-level transaction (single-row persist) |
  | no | yes | any | Persist (+ after_persist) outside; transaction only around stage |
  | yes/no | no | nil | No Commit-level transaction |

  DB transactions use `Dobro.Infra.Repo.transact/2` so `{:error, _}` rolls back.
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
    after_persist = strategies.after_persist
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
          after_persist,
          unit_of_work,
          events,
          tenant,
          message_identity,
          context
        )

      persist_tx? and is_function(after_persist, 2) ->
        persist_and_after_in_transaction(
          persistence_mod,
          persistence_opts,
          delivery_mod,
          delivery_opts,
          after_persist,
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
          after_persist,
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
          after_persist,
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
         after_persist,
         unit_of_work,
         events,
         tenant,
         message_identity,
         context
       ) do
    case Dobro.Infra.Repo.transact(fn ->
           with {:ok, unit_of_work, events} <-
                  persistence_mod.persist(
                    unit_of_work,
                    events,
                    tenant,
                    message_identity,
                    persistence_opts
                  ),
                :ok <- run_after_persist(after_persist, unit_of_work, tenant),
                :ok <- delivery_mod.stage(events, context, delivery_opts) do
             {:ok, {unit_of_work, events}}
           end
         end) do
      {:ok, {unit_of_work, events}} ->
        deliver(delivery_mod, events, context, delivery_opts, unit_of_work)

      {:error, error} ->
        {:error, error}
    end
  end

  # Local DB persist + after_persist (PubSub/None): one transaction for both
  # writes; stage/deliver stay outside so PubSub does not hold the checkout.
  defp persist_and_after_in_transaction(
         persistence_mod,
         persistence_opts,
         delivery_mod,
         delivery_opts,
         after_persist,
         unit_of_work,
         events,
         tenant,
         message_identity,
         context
       ) do
    case Dobro.Infra.Repo.transact(fn ->
           with {:ok, unit_of_work, events} <-
                  persistence_mod.persist(
                    unit_of_work,
                    events,
                    tenant,
                    message_identity,
                    persistence_opts
                  ),
                :ok <- run_after_persist(after_persist, unit_of_work, tenant) do
             {:ok, {unit_of_work, events}}
           end
         end) do
      {:ok, {unit_of_work, events}} ->
        with :ok <- delivery_mod.stage(events, context, delivery_opts) do
          deliver(delivery_mod, events, context, delivery_opts, unit_of_work)
        end

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
         after_persist,
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
         :ok <- run_after_persist(after_persist, unit_of_work, tenant),
         :ok <- stage_in_transaction(delivery_mod, events, context, delivery_opts) do
      deliver(delivery_mod, events, context, delivery_opts, unit_of_work)
    end
  end

  # No transactional stage (PubSub/None) and no after_persist: skip Commit-level
  # transactions so remote HTTP adapters do not pin a pool connection.
  defp persist_and_deliver(
         persistence_mod,
         persistence_opts,
         delivery_mod,
         delivery_opts,
         after_persist,
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
         :ok <- run_after_persist(after_persist, unit_of_work, tenant),
         :ok <- delivery_mod.stage(events, context, delivery_opts) do
      deliver(delivery_mod, events, context, delivery_opts, unit_of_work)
    end
  end

  defp run_after_persist(nil, _unit_of_work, _tenant), do: :ok

  defp run_after_persist(fun, unit_of_work, tenant) when is_function(fun, 2) do
    case fun.(unit_of_work, tenant) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
      other -> {:error, {:invalid_after_persist_result, other}}
    end
  end

  defp stage_in_transaction(delivery_mod, events, context, delivery_opts) do
    case Dobro.Infra.Repo.transact(fn ->
           case delivery_mod.stage(events, context, delivery_opts) do
             :ok -> {:ok, :ok}
             {:error, _} = error -> error
             other -> {:error, {:invalid_stage_result, other}}
           end
         end) do
      {:ok, :ok} -> :ok
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
