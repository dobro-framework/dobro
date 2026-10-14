defmodule Dobro.App.Command.CommitTest do
  use ExUnit.Case, async: false

  alias Dobro.App.Command.Commit
  alias Dobro.App.Command.EventEnrichment
  alias Dobro.App.Command.Strategy
  alias Dobro.Domain.Messages.MessageIdentity
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  defmodule Aggregate do
    defstruct [:id, :name]
  end

  defmodule Created do
    defstruct [:payload, :message_identity]
  end

  defmodule TxPersist do
    def persist(uow, events, _tenant, _mi, _opts), do: {:ok, uow, events}
    def transactional_persist?(_uow, _events, _tenant, _opts), do: true
  end

  defmodule RemotePersist do
    def persist(uow, events, _tenant, _mi, _opts), do: {:ok, uow, events}
    def transactional_persist?(_uow, _events, _tenant, _opts), do: false
  end

  # Mirrors Stateful: assign an id on insert, then enrich events.
  defmodule AssigningPersist do
    def persist(uow, events, _tenant, message_identity, _opts) do
      aggregate = %{uow.aggregate | id: 42}
      uow = %{uow | aggregate: aggregate}
      {:ok, uow, EventEnrichment.enrich(events, message_identity, uow)}
    end

    def transactional_persist?(_uow, _events, _tenant, _opts), do: true
  end

  defmodule NoStage do
    def stage(_events, _ctx, _opts), do: :ok
    def deliver(_events, _ctx, _opts), do: :ok
    def transactional_stage?, do: false
  end

  defmodule FakeRepo do
    @moduledoc false

    def transact(fun, _opts \\ []) do
      depth = Process.get({__MODULE__, :depth}, 0)
      Process.put({__MODULE__, :depth}, depth + 1)

      try do
        case fun.() do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      after
        case Process.get({__MODULE__, :depth}, 1) - 1 do
          n when n <= 0 -> Process.delete({__MODULE__, :depth})
          n -> Process.put({__MODULE__, :depth}, n)
        end
      end
    end

    def in_transaction?, do: Process.get({__MODULE__, :depth}, 0) > 0
  end

  setup do
    previous_repo = Application.get_env(:dobro_ecto, :repo)
    Application.put_env(:dobro_ecto, :repo, FakeRepo)

    on_exit(fn ->
      if previous_repo do
        Application.put_env(:dobro_ecto, :repo, previous_repo)
      else
        Application.delete_env(:dobro_ecto, :repo)
      end
    end)

    uow = UnitOfWork.new(%{aggregate: %Aggregate{id: nil, name: "Acme"}})
    events = [:registered]
    {:ok, uow: uow, events: events}
  end

  test "remote persist + non-transactional stage does not open a DB transaction", %{
    uow: uow,
    events: events
  } do
    strategies = %Strategy{
      persistence: {RemotePersist, []},
      event_delivery: {NoStage, []}
    }

    assert {:ok, ^uow, ^events} =
             Commit.run(strategies, uow, events, nil, %{}, uow.aggregate)

    refute FakeRepo.in_transaction?
  end

  test "local persist + non-transactional stage without after_persist skips Commit txn", %{
    uow: uow,
    events: events
  } do
    strategies = %Strategy{
      persistence: {TxPersist, []},
      event_delivery: {NoStage, []}
    }

    assert {:ok, ^uow, ^events} =
             Commit.run(strategies, uow, events, nil, %{}, uow.aggregate)

    refute FakeRepo.in_transaction?
  end

  test "remote persist runs after_persist after persist (outside DB txn)", %{
    uow: uow,
    events: events
  } do
    test_pid = self()

    strategies = %Strategy{
      persistence: {RemotePersist, []},
      event_delivery: {NoStage, []},
      after_persist: fn persisted_uow, tenant ->
        send(test_pid, {:after_persist, persisted_uow, tenant, FakeRepo.in_transaction?()})
        :ok
      end
    }

    assert {:ok, ^uow, ^events} =
             Commit.run(strategies, uow, events, :tenant, %{}, uow.aggregate)

    assert_received {:after_persist, ^uow, :tenant, false}
  end

  test "remote persist surfaces after_persist errors", %{uow: uow, events: events} do
    strategies = %Strategy{
      persistence: {RemotePersist, []},
      event_delivery: {NoStage, []},
      after_persist: fn _uow, _tenant -> {:error, :link_failed} end
    }

    assert {:error, :link_failed} =
             Commit.run(strategies, uow, events, nil, %{}, uow.aggregate)
  end

  test "commit enriches created event ids after stateful-style insert", %{uow: uow} do
    message_identity = MessageIdentity.new!(%{id: "command-id"})

    event = %Created{
      payload: %{id: nil, name: "Acme"},
      message_identity: MessageIdentity.new!(%{id: "event-id"})
    }

    strategies = %Strategy{
      persistence: {AssigningPersist, []},
      event_delivery: {NoStage, []}
    }

    assert {:ok, persisted, [enriched_event]} =
             Commit.run(
               strategies,
               uow,
               [event],
               nil,
               message_identity,
               uow.aggregate
             )

    assert persisted.aggregate.id == 42
    assert enriched_event.payload.id == 42
  end

  test "after_persist runs in the same transaction as local persist", %{uow: uow} do
    test_pid = self()
    message_identity = MessageIdentity.new!(%{id: "command-id-2"})

    event = %Created{
      payload: %{id: nil, name: "Linked"},
      message_identity: MessageIdentity.new!(%{id: "event-id-2"})
    }

    strategies = %Strategy{
      persistence: {AssigningPersist, []},
      event_delivery: {NoStage, []},
      after_persist: fn persisted_uow, _tenant ->
        send(test_pid, {
          :after_persist,
          persisted_uow.aggregate.id,
          FakeRepo.in_transaction?()
        })

        {:error, :force_rollback}
      end
    }

    assert {:error, :force_rollback} =
             Commit.run(strategies, uow, [event], nil, message_identity, uow.aggregate)

    assert_received {:after_persist, 42, true}
    refute FakeRepo.in_transaction?
  end
end
