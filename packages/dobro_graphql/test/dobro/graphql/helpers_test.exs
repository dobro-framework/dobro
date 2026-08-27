defmodule Dobro.Graphql.HelpersTest do
  use ExUnit.Case, async: true

  alias AbsintheErrorPayload.ValidationMessage
  alias Dobro.Error
  alias Dobro.Graphql.Helpers.{Errors, Mutation}

  describe "Errors.format/1" do
    test "passes through ok results" do
      assert Errors.format({:ok, %{id: 1}}) == {:ok, %{id: 1}}
    end

    test "formats Dobro.Error for Absinthe query errors" do
      error =
        Error.new(:query_validation_error, description: "invalid sort field: tenant_id")

      assert {:error, [formatted]} = Errors.format({:error, error})

      assert formatted == %{
               message: "invalid sort field: tenant_id",
               code: :query_validation_error
             }
    end

    test "humanizes missing descriptions for query errors" do
      assert {:error, [formatted]} = Errors.format({:error, Error.new(:not_found)})
      assert formatted == %{message: "not found", code: :not_found}
    end

    test "formats a list of Dobro.Error values" do
      errors = [
        Error.new(:query_validation_error, description: "invalid sort field: tenant_id"),
        Error.new(:not_found, description: "missing", path: "id")
      ]

      assert {:error, [first, second]} = Errors.format({:error, errors})
      assert first.message == "invalid sort field: tenant_id"
      assert second == %{message: "missing", code: :not_found, field: "id"}
    end
  end

  describe "Mutation.payload/1" do
    test "formats Dobro.Error as validation messages" do
      error = Error.new(:invalid, description: "bad value", path: "name")

      assert {:error, [%ValidationMessage{} = message]} = Mutation.payload({:error, error})
      assert message.message == "bad value"
      assert message.code == :invalid
      assert message.field == "name"
    end

    test "preserves nil descriptions on validation messages" do
      error = %Error{path: :name, reason: :required}

      assert {:error, [%ValidationMessage{} = message]} = Mutation.payload({:error, [error]})
      assert message.message == nil
      assert message.code == :required
      assert message.field == :name
    end

    test "does not echo reason atoms as the validation message" do
      error = Error.new(:must_have_contact, description: :must_have_contact)

      assert {:error, [%ValidationMessage{} = message]} = Mutation.payload({:error, error})
      assert message.code == :must_have_contact
      assert message.message == nil
    end
  end
end
