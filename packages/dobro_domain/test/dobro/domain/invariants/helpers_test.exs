defmodule Dobro.Domain.Invariants.HelpersTest do
  use ExUnit.Case, async: true

  alias Dobro.Domain.Invariants.Helpers
  alias Dobro.Error

  defmodule ContactAggregate do
    use Dobro.Domain.Invariants

    definvariant must_have_contact(%{email: email}) when not is_nil(email), do: :ok
    definvariant must_have_contact(%{phone: phone}) when not is_nil(phone), do: :ok
    definvariant must_have_contact(_), do: {:error, :must_have_contact}
  end

  defmodule DescribedAggregate do
    use Dobro.Domain.Invariants

    definvariant must_be_named(%{name: name}) when is_binary(name), do: :ok
    definvariant must_be_named(_), do: {:error, "name is required"}
  end

  test "atom invariant errors become reason codes without a description" do
    assert {:error, %Error{reason: :must_have_contact, description: nil}} =
             Helpers.check_invariants(ContactAggregate, %{value: %{}})
  end

  test "binary invariant errors keep the invariant name as reason and set description" do
    assert {:error, %Error{reason: :must_be_named, description: "name is required"}} =
             Helpers.check_invariants(DescribedAggregate, %{value: %{}})
  end

  test "passing invariants return :ok" do
    assert :ok = Helpers.check_invariants(ContactAggregate, %{value: %{email: "a@b.c"}})
  end
end
