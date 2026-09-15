defmodule Dobro.Runtime.AggregateActor do
  @moduledoc """
  GenServer concurrency gateway for a single aggregate identity.

  In cluster mode the process holds an `ActorLock` for its key so only one
  instance runs cluster-wide. Idle actors stop after a TTL and release the lock.
  """
  use GenServer

  import Dobro.Runtime.Persistence

  alias Dobro.App.Auth.TenantContext
  alias Dobro.Error
  alias Dobro.Runtime.ActorLock
  alias Dobro.Runtime.ActorRegistry

  defmodule Config do
    @moduledoc false
    use TypedStruct

    typedstruct do
      field :aggregate_module, module()
      field :identity, map()
      field :tenant, TenantContext.t()
      field :load_fn, atom()
      field :persistence_strategy, atom()
      field :actor_key, term()
      field :holds_lock, boolean(), default: false
    end
  end

  @active_ttl 600_000
  @failed_ttl 5_000
  @lock_released Dobro.Runtime.ActorLock.Postgres.lock_released_message()

  defstruct [:config, :unit_of_work, :load_error, :ttl_ref, pending_executes: []]

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :actor_key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(opts) do
    aggregate_module = Keyword.fetch!(opts, :aggregate_module)
    identity = Keyword.fetch!(opts, :identity)
    tenant = Keyword.fetch!(opts, :tenant)
    load_fn = Keyword.get(opts, :load_fn, :get_by)
    persistence_strategy = Keyword.get(opts, :persistence_strategy, :stateful)
    actor_key = Keyword.fetch!(opts, :actor_key)
    name = Keyword.get(opts, :name, ActorRegistry.via(actor_key))

    state = %__MODULE__{
      config: %{
        aggregate_module: aggregate_module,
        identity: identity,
        tenant: tenant,
        load_fn: load_fn,
        persistence_strategy: persistence_strategy,
        actor_key: actor_key,
        holds_lock: false
      },
      unit_of_work: nil
    }

    GenServer.start_link(__MODULE__, state, name: name)
  end

  @doc """
  Stable term key for an aggregate actor.

  `tenant` must already be normalized via `Dobro.Tenant.normalize/1` with an immutable `:id`.
  """
  def actor_key(aggregate_module, tenant, identity) do
    {:aggregate_actor, aggregate_module, TenantContext.partition_key(tenant),
     identity_value_for(identity)}
  end

  @doc false
  def actor_name(aggregate_module, tenant, identity) do
    actor_key(aggregate_module, tenant, identity)
  end

  defp identity_value_for(identity) when is_map(identity) do
    identity
    |> Enum.sort()
    |> Enum.map_join(":", fn {key, value} -> "#{key}:#{value}" end)
  end

  defp identity_value_for(identity), do: to_string(identity)

  @impl GenServer
  def init(%__MODULE__{} = state) do
    Process.flag(:trap_exit, true)

    case ActorLock.try_acquire(state.config.actor_key, self()) do
      :ok ->
        state = put_in(state.config.holds_lock, true)
        {:ok, state, {:continue, :load_aggregate}}

      {:error, :locked} ->
        {:stop, :lock_not_acquired}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:load_aggregate, %__MODULE__{} = state) do
    case load(
           state.config.aggregate_module,
           state.config.load_fn,
           state.config.identity,
           state.config.tenant,
           persistence_strategy: state.config.persistence_strategy
         ) do
      {:ok, unit_of_work} ->
        state =
          %{state | unit_of_work: unit_of_work}
          |> schedule_ttl(:active)
          |> reply_pending_executes()

        {:noreply, state}

      {:error, error} ->
        state =
          %{state | load_error: error}
          |> schedule_ttl(:failed)
          |> reply_pending_errors(error)

        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call({:execute, _, _, _, _}, _from, %{load_error: error} = state)
      when not is_nil(error) do
    {:reply, {:error, error}, state}
  end

  def handle_call(
        {:execute, aggregate_fn, contract, message_identity, strategies},
        from,
        %{unit_of_work: nil, load_error: nil} = state
      ) do
    {:noreply, enqueue_execute(state, from, aggregate_fn, contract, message_identity, strategies)}
  end

  def handle_call(
        {:execute, aggregate_fn, contract, message_identity, strategies},
        _from,
        %__MODULE__{unit_of_work: unit_of_work, config: config} = state
      )
      when not is_nil(unit_of_work) do
    {reply, state} =
      run_execute(
        state,
        config,
        unit_of_work,
        aggregate_fn,
        contract,
        message_identity,
        strategies
      )

    {:reply, reply, state}
  end

  def execute(name, aggregate_fn, contract, message_identity, strategies) do
    GenServer.call(name, {:execute, aggregate_fn, contract, message_identity, strategies})
  catch
    :exit, {{:error, error}, _} ->
      {:error, error}

    :exit, {{:shutdown, {:error, error}}, _} ->
      {:error, error}

    :exit, {:noproc, _} ->
      {:error, :aggregate_unavailable}
  end

  @impl GenServer
  def handle_info(:ttl_expired, state) do
    reason = state.load_error || :idle_timeout
    {:stop, {:shutdown, reason}, state}
  end

  def handle_info({@lock_released, key, _reason}, %{config: %{actor_key: key}} = state) do
    {:stop, {:shutdown, :lock_released}, %{state | config: %{state.config | holds_lock: false}}}
  end

  def handle_info({@lock_released, _key, _reason}, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{config: %{holds_lock: true, actor_key: key}}) do
    ActorLock.release(key)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @doc "Via tuple for the AggregateActor."
  def via(aggregate_module, tenant, identity) do
    ActorRegistry.via(actor_key(aggregate_module, tenant, identity))
  end

  defp enqueue_execute(state, from, aggregate_fn, contract, message_identity, strategies) do
    %{
      state
      | pending_executes: [
          {from, aggregate_fn, contract, message_identity, strategies} | state.pending_executes
        ]
    }
  end

  defp reply_pending_executes(%{pending_executes: []} = state), do: state

  defp reply_pending_executes(%{pending_executes: pending} = state) do
    Enum.reduce(pending, %{state | pending_executes: []}, fn {from, aggregate_fn, contract,
                                                              message_identity, strategies},
                                                             state ->
      {reply, state} =
        run_execute(
          state,
          state.config,
          state.unit_of_work,
          aggregate_fn,
          contract,
          message_identity,
          strategies
        )

      GenServer.reply(from, reply)
      state
    end)
  end

  defp reply_pending_errors(%{pending_executes: pending} = state, error) do
    Enum.each(pending, fn
      {from, _, _, _, _} -> GenServer.reply(from, {:error, error})
      {from, _, _} -> GenServer.reply(from, {:error, error})
    end)

    %{state | pending_executes: []}
  end

  defp run_execute(
         state,
         config,
         unit_of_work,
         aggregate_fn,
         contract,
         message_identity,
         strategies
       ) do
    alias Dobro.App.Command.Commit

    case apply(config.aggregate_module, aggregate_fn, [unit_of_work.aggregate, contract]) do
      {:ok, result} ->
        unit_of_work = %{unit_of_work | aggregate: result.value}

        case Commit.run(
               strategies,
               unit_of_work,
               result.events,
               config.tenant,
               message_identity,
               unit_of_work.aggregate
             ) do
          {:ok, unit_of_work, events} ->
            state = %{state | unit_of_work: unit_of_work} |> schedule_ttl(:active)
            {{:ok, %{value: unit_of_work.aggregate, events: events}}, state}

          {:error, %Error{reason: :concurrent_modification} = error} ->
            {{:error, error}, invalidate_state(state)}

          {:error, error} ->
            {{:error, error}, state}
        end

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  defp invalidate_state(state) do
    %{state | unit_of_work: nil, load_error: Error.new(:concurrent_modification)}
    |> schedule_ttl(:failed)
  end

  defp schedule_ttl(state, :active) do
    cancel_ttl(state)
    ref = Process.send_after(self(), :ttl_expired, @active_ttl)
    %{state | ttl_ref: ref}
  end

  defp schedule_ttl(state, :failed) do
    cancel_ttl(state)
    ref = Process.send_after(self(), :ttl_expired, @failed_ttl)
    %{state | ttl_ref: ref}
  end

  defp cancel_ttl(%{ttl_ref: nil}), do: :ok

  defp cancel_ttl(%{ttl_ref: ref}) do
    Process.cancel_timer(ref)
    :ok
  end
end
