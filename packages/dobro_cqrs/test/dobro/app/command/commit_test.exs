defmodule Dobro.App.Command.CommitTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Command.Commit
  alias Dobro.App.Command.Strategy
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  defmodule Aggregate do
    defstruct [:id, :name]
  end

  defmodule TxPersist do
    def persist(uow, events, _tenant, _mi, _opts), do: {:ok, uow, events}
    def transactional_persist?(_uow, _events, _tenant, _opts), do: true
  end

  defmodule RemotePersist do
    def persist(uow, events, _tenant, _mi, _opts), do: {:ok, uow, events}
    def transactional_persist?(_uow, _events, _tenant, _opts), do: false
  end

  defmodule NoStage do
    def stage(_events, _ctx, _opts), do: :ok
    def deliver(_events, _ctx, _opts), do: :ok
    def transactional_stage?, do: false
  end

  setup do
    uow = UnitOfWork.new(%{aggregate: %Aggregate{id: nil, name: "Acme"}})
    events = [:registered]
    {:ok, uow: uow, events: events}
  end

  # Paths with transactional_stage? true open Repo.transaction and need a
  # configured Ecto repo — covered when the host app runs command tests.
  # These cases assert Commit does not open a transaction when stage is not DB-backed.

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
  end

  test "local persist + non-transactional stage does not open a DB transaction", %{
    uow: uow,
    events: events
  } do
    strategies = %Strategy{
      persistence: {TxPersist, []},
      event_delivery: {NoStage, []}
    }

    assert {:ok, ^uow, ^events} =
             Commit.run(strategies, uow, events, nil, %{}, uow.aggregate)
  end
end
