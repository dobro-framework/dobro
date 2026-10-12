defmodule Dobro.Schema.OneOfInputTest do
  use ExUnit.Case, async: true

  alias Dobro.Schema.OneOfInput

  describe "new/1" do
    test "builds from a keyword list" do
      assert %OneOfInput{variants: [a: :string, b: :integer]} =
               OneOfInput.new(a: :string, b: :integer)
    end
  end

  describe "unwrap/2" do
    setup do
      {:ok, one_of: OneOfInput.new(create_resource: :map, send_notification: :map)}
    end

    test "returns the single present variant", %{one_of: one_of} do
      assert {:ok, {:create_resource, %{resource: "amount"}}} =
               OneOfInput.unwrap(one_of, %{create_resource: %{resource: "amount"}})
    end

    test "accepts string keys", %{one_of: one_of} do
      assert {:ok, {:send_notification, %{}}} =
               OneOfInput.unwrap(one_of, %{"send_notification" => %{}})
    end

    test "rejects empty maps", %{one_of: one_of} do
      assert {:error, :one_of_required} = OneOfInput.unwrap(one_of, %{})
    end

    test "rejects multiple variants", %{one_of: one_of} do
      assert {:error, :one_of_exclusive} =
               OneOfInput.unwrap(one_of, %{create_resource: %{}, send_notification: %{}})
    end

    test "ignores explicit nils", %{one_of: one_of} do
      assert {:ok, {:create_resource, %{}}} =
               OneOfInput.unwrap(one_of, %{create_resource: %{}, send_notification: nil})
    end
  end
end
