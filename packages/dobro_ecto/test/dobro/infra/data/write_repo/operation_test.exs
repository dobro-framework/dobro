defmodule Dobro.Infra.Data.WriteRepo.OperationTest do
  use ExUnit.Case, async: true

  alias Dobro.Infra.Data.WriteRepo.Operation
  alias Dobro.Infra.Data.WriteRepo.UnitOfWork

  defmodule Record do
    @moduledoc false
    defstruct [:id, :version]
  end

  defmodule RecordDeleted do
    @moduledoc false
    defstruct [:payload]
  end

  describe "resolve/2" do
    test "returns :insert when aggregate has no id" do
      unit_of_work = UnitOfWork.new(%{aggregate: %Record{version: 0}, schema: nil})

      assert :insert = Operation.resolve(unit_of_work, [])
    end

    test "returns :update for existing aggregate without delete events" do
      unit_of_work = UnitOfWork.new(%{aggregate: %Record{id: 1, version: 1}, schema: nil})

      assert :update = Operation.resolve(unit_of_work, [])
    end

    test "returns :delete when a Deleted event is present" do
      unit_of_work = UnitOfWork.new(%{aggregate: %Record{id: 1, version: 1}, schema: nil})
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
