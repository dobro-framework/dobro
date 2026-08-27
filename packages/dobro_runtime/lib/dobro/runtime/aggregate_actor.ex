defmodule Dobro.Runtime.AggregateActor do
  @moduledoc """
  Actor for an aggregate - as a GenServer
  """
  use GenServer
  import Dobro.Runtime.Persistence
  alias Dobro.App.Auth.TenantContext

  defmodule Config do
    @moduledoc """
    Config for the AggregateActor
    """
    use TypedStruct

    typedstruct do
      field :aggregate_module, module()
      field :repo_module, module()
      field :identity, map()
      field :tenant, TenantContext.t()
      field :load_fn, atom()
      field :persistence_strategy, atom()
    end
  end

  @active_ttl 600_000
  @failed_ttl 5_000

  defstruct [:config, :unit_of_work, :load_error, :ttl_ref, pending_executes: []]

  def start_link(opts) do
    aggregate_module = Keyword.fetch!(opts, :aggregate_module)
    identity = Keyword.fetch!(opts, :identity)
    tenant = Keyword.fetch!(opts, :tenant)
    load_fn = Keyword.get(opts, :load_fn, :get_by)
    persistence_strategy = Keyword.get(opts, :persistence_strategy, :stateful)
    name = Keyword.fetch!(opts, :name)

    state = %__MODULE__{
      config: %{
        aggregate_module: aggregate_module,
        identity: identity,
        tenant: tenant,
        load_fn: load_fn,
        persistence_strategy: persistence_strategy
      },
      unit_of_work: nil
    }

    GenServer.start_link(__MODULE__, state, name: name)
  end

  @doc """
  Generates a unique name for the AggregateActor.

  `tenant` must already be normalized via `Dobro.Tenant.normalize/1` (as done by
  `AggregateSupervisor`) with an immutable `:id`. Actors are never keyed by
  identifier, which can be renamed while actors are running.
  """
  def actor_name(aggregate_module, tenant, identity) do
    tenant_key = TenantContext.partition_key(tenant)
    identity_value = identity_value_for(identity)

    "aggregate_actor_#{aggregate_module}_#{tenant_key}_#{identity_value}"
    |> String.to_atom()
  end

  # converts to id:123:key:678 format (sorted for stable naming)
  defp identity_value_for(identity) when is_map(identity) do
    identity
    |> Enum.sort()
    |> Enum.map_join(":", fn {key, value} -> "#{key}:#{value}" end)
  end

  defp identity_value_for(identity), do: to_string(identity)

  @impl GenServer
  def init(%__MODULE__{} = state) do
    {:ok, state, {:continue, :load_aggregate}}
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

  @doc """
  Executes the aggregate function
  """
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
    reason =
      state.load_error || :idle_timeout

    {:stop, {:shutdown, reason}, state}
  end

  @doc """
  Generates a via tuple for the AggregateActor
  """
  def via(aggregate_module, tenant, identity) do
    actor_name = actor_name(aggregate_module, tenant, identity)
    {:via, Registry, {Dobro.Runtime.Registry, actor_name}}
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
    Enum.each(pending, fn {from, _, _} ->
      GenServer.reply(from, {:error, error})
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

          {:error, error} ->
            {{:error, error}, state}
        end

      {:error, error} ->
        {{:error, error}, state}
    end
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
