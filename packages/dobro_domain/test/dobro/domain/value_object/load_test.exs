defmodule Dobro.Domain.ValueObject.LoadTest do
  use ExUnit.Case, async: true

  alias Dobro.Domain.TestFixtures.Tag

  test "load hydrates persisted data without validations or invariants" do
    assert {:ok, %Tag{name: "legacy", values: []}} =
             Tag.load(%{name: "legacy", values: []})

    assert {:error, _} = Tag.new(%{name: "legacy", values: []})
  end
end
