defmodule Dobro.Graphql.OneOfTest do
  use ExUnit.Case, async: true

  Module.register_attribute(__MODULE__, :referenced_types, accumulate: true)

  alias Dobro.Graphql.Schema
  alias Dobro.Schema.{OneOf, OneOfInput}

  defmodule CreateResourceParams do
    use Dobro.Schema

    schema do
      field :resource, :string
    end
  end

  defmodule SendNotificationParams do
    use Dobro.Schema

    schema do
      field :notification_identifier, :string
    end
  end

  defmodule ActionParams do
    use Dobro.Schema.OneOf,
      types: [CreateResourceParams, SendNotificationParams],
      discr: &__MODULE__.discr/1

    def discr(%{__struct__: CreateResourceParams}), do: CreateResourceParams
    def discr(%{__struct__: SendNotificationParams}), do: SendNotificationParams
    def discr(%{notification_identifier: _}), do: SendNotificationParams
    def discr(%{"notification_identifier" => _}), do: SendNotificationParams
    def discr(_), do: CreateResourceParams
  end

  describe "type_from_schema/4" do
    test "rejects one_of_input on result fields" do
      one_of = OneOfInput.new(create_resource_params: CreateResourceParams)

      assert_raise ArgumentError, ~r/only supported for GraphQL inputs/, fn ->
        Schema.type_from_schema(__MODULE__, one_of, %{}, :result)
      end
    end

    test "maps OneOf modules on input fields to a named @oneOf input type" do
      assert Schema.type_from_schema(__MODULE__, ActionParams, %{}, :input) ==
               :action_params_input
    end

    test "maps OneOf modules on result fields to a union type" do
      assert Schema.type_from_schema(__MODULE__, ActionParams, %{}, :result) == :action_params
    end
  end

  describe "OneOf.keyed_variants/1" do
    test "derives keys from underscored leaf module names" do
      assert OneOf.keyed_variants(ActionParams) == [
               create_resource_params: CreateResourceParams,
               send_notification_params: SendNotificationParams
             ]
    end
  end

  describe "build_type/3" do
    test "builds a result union AST with member types and resolve_type" do
      ast = Schema.build_type(__MODULE__, ActionParams, gql_type: :union, context_map: %{})
      source = Macro.to_string(ast)

      assert source =~ "union"
      assert source =~ "resolve_type"
      assert source =~ "create_resource_params"
      assert source =~ "send_notification_params"
    end

    test "builds an input AST with @oneOf directive and mechanical variant fields" do
      ast = Schema.build_type(__MODULE__, ActionParams, gql_type: :union_input, context_map: %{})
      source = Macro.to_string(ast)

      assert source =~ "input_object"
      assert source =~ "action_params_input"
      assert source =~ "directive(:one_of)"
      assert source =~ "create_resource_params"
      assert source =~ "send_notification_params"
    end
  end
end
