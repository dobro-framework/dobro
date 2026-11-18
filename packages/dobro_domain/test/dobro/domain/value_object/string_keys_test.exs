defmodule Dobro.Domain.ValueObject.StringKeysTest do
  use ExUnit.Case, async: true

  alias Dobro.Domain.TestFixtures.Consent

  defmodule Contracts do
    use Dobro.Contract

    defcontract Holder do
      field(:consent, Consent)
    end
  end

  alias Contracts.Holder

  # As read back from a jsonb column.
  @json %{"email" => true, "post" => false}

  test "new/1 casts string-keyed input" do
    assert {:ok, %Consent{email: true, post: false}} = Consent.new(@json)
  end

  test "load/1 hydrates string-keyed input" do
    assert {:ok, %Consent{email: true, post: false}} = Consent.load(@json)
  end

  test "a contract field casts a string-keyed value object" do
    assert {:ok, %{consent: %Consent{email: true}}} = Holder.new(%{consent: @json})
  end

  test "unknown string keys are ignored" do
    assert {:ok, %Consent{email: true}} =
             Consent.new(Map.put(@json, "not_a_field_#{System.unique_integer()}", 1))
  end
end
