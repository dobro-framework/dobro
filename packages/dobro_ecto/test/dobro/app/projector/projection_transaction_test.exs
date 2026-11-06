defmodule Dobro.App.Projector.ProjectionTransactionTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Projector.ProjectionTransaction

  test "a single :ok has no effects" do
    assert {:ok, []} = ProjectionTransaction.normalize_project_result(:ok)
  end

  test "a single after_commit result wraps one or many functions" do
    fun = fn -> :ok end

    assert {:ok, [^fun]} =
             ProjectionTransaction.normalize_project_result({:ok, after_commit: fun})

    assert {:ok, [^fun, ^fun]} =
             ProjectionTransaction.normalize_project_result({:ok, after_commit: [fun, fun]})
  end

  test "a list of results merges after_commit effects in order" do
    a = fn -> :a end
    b = fn -> :b end

    assert {:ok, [^a, ^b]} =
             ProjectionTransaction.normalize_project_result([
               :ok,
               {:ok, after_commit: a},
               {:ok, after_commit: [b]}
             ])
  end

  test "a list stops at the first error" do
    assert {:error, :boom} =
             ProjectionTransaction.normalize_project_result([
               {:ok, after_commit: fn -> :ok end},
               {:error, :boom},
               :ok
             ])
  end

  test "a bare keyword list is rejected" do
    assert {:error, {:unexpected_projection_result, [after_commit: _]}} =
             ProjectionTransaction.normalize_project_result(after_commit: fn -> :ok end)
  end
end
