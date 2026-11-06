defmodule Dobro.Infra.Data.WriteRepo.OperationTest do
  use ExUnit.Case, async: true

  alias Dobro.Infra.Data.WriteRepo.Operation
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  defmodule RecordDeleted do
    @moduledoc false
    defstruct [:payload]
  end

  defmodule IdentifiedRecord do
    @moduledoc false
    defstruct [:id, :version]

    def __identity_fields__, do: [:id]
  end

  describe "resolve/2" do
    test "returns :insert when schema is nil" do
      unit_of_work =
        UnitOfWork.new(%{aggregate: %IdentifiedRecord{id: 1, version: 0}, schema: nil})

      assert :insert = Operation.resolve(unit_of_work, [])
    end

    test "returns :insert when identity is unset" do
      unit_of_work =
        UnitOfWork.new(%{
          aggregate: %IdentifiedRecord{version: 0},
          schema: %IdentifiedRecord{id: 1}
        })

      assert :insert = Operation.resolve(unit_of_work, [])
    end

    test "returns :update for existing aggregate without delete events" do
      unit_of_work =
        UnitOfWork.new(%{
          aggregate: %IdentifiedRecord{id: 1, version: 1},
          schema: %IdentifiedRecord{id: 1}
        })

      assert :update = Operation.resolve(unit_of_work, [])
    end

    test "returns :delete when a Deleted event is present" do
      unit_of_work =
        UnitOfWork.new(%{
          aggregate: %IdentifiedRecord{id: 1, version: 1},
          schema: %IdentifiedRecord{id: 1}
        })

      event = %RecordDeleted{payload: %{id: 1}}

      assert :delete = Operation.resolve(unit_of_work, [event])
    end

    test "returns :delete for a Deleted event even when schema is already gone" do
      unit_of_work =
        UnitOfWork.new(%{aggregate: %IdentifiedRecord{id: 1, version: 2}, schema: nil})

      event = %RecordDeleted{payload: %{id: 1}}

      assert :delete = Operation.resolve(unit_of_work, [event])
    end
  end

  describe "delete_event?/1" do
    test "detects event modules ending in Deleted" do
      event = %RecordDeleted{payload: %{id: 1}}

      assert Operation.delete_event?([event])
      refute Operation.delete_event?([])
    end
  end
end
