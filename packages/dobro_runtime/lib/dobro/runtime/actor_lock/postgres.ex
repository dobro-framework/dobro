defmodule Dobro.Runtime.ActorLock.Postgres do
  @moduledoc """
  Postgres session advisory locks + lease rows for cluster-wide actor ownership.

  Requires:

  - A dedicated Postgrex connection (not transaction-pooled PgBouncer / RDS Proxy)
  - The `actor_leases` table (see Dobro / FM migrations)

  Start under your application supervisor via `Dobro.Runtime.ActorLock.child_specs/0`.
  """

  @behaviour Dobro.Runtime.ActorLock

  use GenServer

  alias Dobro.Infra.Repo
  alias Dobro.Runtime.ActorLock.LeaseSchema

  require Logger

  defstruct conn: nil,
            locks: %{},
            schema_prefix: "shared",
            query_timeout: 5_000

  @lock_released {__MODULE__, :lock_released}

  @doc false
  def child_specs(opts) do
    [
      %{
        id: __MODULE__.Postgrex,
        start: {__MODULE__, :start_postgrex, [opts]}
      },
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    ]
  end

  @doc false
  def start_postgrex(opts) do
    postgrex_opts =
      default_postgrex_opts()
      |> Keyword.merge(Keyword.get(opts, :postgrex, []))
      |> Keyword.put(:name, __MODULE__.Postgrex)
      |> Keyword.put_new(:pool_size, 1)
      |> Keyword.put_new(:backoff_type, :stop)

    Postgrex.start_link(postgrex_opts)
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def try_acquire(key, owner) when is_pid(owner) do
    GenServer.call(__MODULE__, {:try_acquire, key, owner})
  end

  @impl true
  def release(key) do
    GenServer.call(__MODULE__, {:release, key})
  end

  @impl true
  def whereis(key) do
    GenServer.call(__MODULE__, {:whereis, key})
  end

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      conn: Keyword.get(opts, :conn, __MODULE__.Postgrex),
      schema_prefix: Keyword.get(opts, :schema_prefix, "shared"),
      query_timeout: Keyword.get(opts, :query_timeout, 5_000)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:try_acquire, key, owner}, _from, state) do
    # Session advisory locks are re-entrant on the same Postgrex connection, so
    # local ownership must be checked before calling pg_try_advisory_lock/2.
    case Map.get(state.locks, key) do
      %{owner: ^owner} ->
        {:reply, :ok, state}

      %{owner: _other} ->
        {:reply, {:error, :locked}, state}

      nil ->
        {ns, id} = advisory_keys(key)

        case pg_try_lock(state, ns, id) do
          :ok ->
            monitor = Process.monitor(owner)
            write_lease(state, key, owner)

            locks =
              Map.put(state.locks, key, %{
                owner: owner,
                monitor: monitor,
                ns: ns,
                id: id
              })

            {:reply, :ok, %{state | locks: locks}}

          {:error, :locked} = err ->
            {:reply, err, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:release, key}, _from, state) do
    state = do_release(key, state)
    {:reply, :ok, state}
  end

  def handle_call({:whereis, key}, _from, state) do
    reply =
      case Map.get(state.locks, key) do
        %{owner: owner} ->
          {:ok, owner}

        nil ->
          case read_lease(state, key) do
            %{node: node, owner: owner_str} ->
              self_node = Node.self()

              case safe_node_atom(node) do
                {:ok, ^self_node} ->
                  case decode_pid(owner_str) do
                    {:ok, pid} when is_pid(pid) ->
                      if Process.alive?(pid), do: {:ok, pid}, else: :unknown

                    _ ->
                      :unknown
                  end

                {:ok, node_atom} ->
                  case decode_pid(owner_str) do
                    {:ok, pid} -> {:ok, node_atom, pid}
                    _ -> {:ok, node_atom, nil}
                  end

                :error ->
                  :unknown
              end

            nil ->
              :unknown
          end
      end

    {:reply, reply, state}
  end

  defp safe_node_atom(node) when is_binary(node) do
    {:ok, String.to_existing_atom(node)}
  rescue
    ArgumentError -> :error
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    key =
      Enum.find_value(state.locks, fn
        {k, %{monitor: ^monitor, owner: ^pid}} -> k
        _ -> nil
      end)

    state =
      if key do
        notify_lock_released(pid, key, reason)
        do_release(key, state)
      else
        state
      end

    {:noreply, state}
  end

  defp do_release(key, state) do
    case Map.pop(state.locks, key) do
      {nil, locks} ->
        clear_lease(state, key)
        %{state | locks: locks}

      {%{monitor: monitor, ns: ns, id: id}, locks} ->
        Process.demonitor(monitor, [:flush])
        _ = pg_unlock(state, ns, id)
        clear_lease(state, key)
        %{state | locks: locks}
    end
  end

  defp pg_try_lock(%{conn: conn, query_timeout: timeout}, ns, id) do
    case Postgrex.query(conn, "SELECT pg_try_advisory_lock($1, $2)", [ns, id], timeout: timeout) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :locked}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pg_unlock(%{conn: conn, query_timeout: timeout}, ns, id) do
    Postgrex.query(conn, "SELECT pg_advisory_unlock($1, $2)", [ns, id], timeout: timeout)
  end

  defp write_lease(state, key, owner) do
    prefix = state.schema_prefix
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert(
      %LeaseSchema{
        lock_key: encode_key(key),
        node: Atom.to_string(Node.self()),
        owner: encode_pid(owner),
        inserted_at: now,
        updated_at: now
      },
      prefix: prefix,
      on_conflict: {:replace, [:node, :owner, :updated_at]},
      conflict_target: [:lock_key]
    )
  rescue
    error ->
      Logger.warning("actor lease write failed: #{inspect(error)}")
      {:error, error}
  end

  defp read_lease(state, key) do
    import Ecto.Query

    LeaseSchema
    |> where([l], l.lock_key == ^encode_key(key))
    |> Repo.one(prefix: state.schema_prefix)
  rescue
    _ -> nil
  end

  defp clear_lease(state, key) do
    import Ecto.Query

    from(l in LeaseSchema, where: l.lock_key == ^encode_key(key))
    |> Repo.delete_all(prefix: state.schema_prefix)
  rescue
    error ->
      Logger.warning("actor lease clear failed: #{inspect(error)}")
      {0, nil}
  end

  defp advisory_keys(key) do
    ns = Bitwise.band(:erlang.phash2({:dobro_actor_lock_ns, key}), 0x7FFFFFFF)
    id = Bitwise.band(:erlang.phash2({:dobro_actor_lock_id, key}), 0x7FFFFFFF)
    {ns, id}
  end

  defp encode_key(key), do: Base.encode64(:erlang.term_to_binary(key), padding: false)

  defp encode_pid(pid), do: Base.encode64(:erlang.term_to_binary(pid), padding: false)

  defp decode_pid(encoded) when is_binary(encoded) do
    {:ok, :erlang.binary_to_term(Base.decode64!(encoded, padding: false))}
  rescue
    _ -> :error
  end

  defp notify_lock_released(owner, key, reason) do
    if Process.alive?(owner) do
      send(owner, {@lock_released, key, reason})
    end
  end

  defp default_postgrex_opts do
    repo = Dobro.Config.repo!()
    config = repo.config()

    [
      hostname: Keyword.get(config, :hostname, "localhost"),
      port: Keyword.get(config, :port, 5432),
      username: Keyword.get(config, :username),
      password: Keyword.get(config, :password),
      database: Keyword.get(config, :database),
      ssl: Keyword.get(config, :ssl, false),
      socket_options: Keyword.get(config, :socket_options, [])
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc "Message sent to an owner when its advisory lock is lost."
  def lock_released_message, do: @lock_released
end
