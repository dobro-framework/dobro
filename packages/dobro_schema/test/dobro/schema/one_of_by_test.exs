defmodule Dobro.Schema.OneOfByTest do
  use ExUnit.Case, async: true
  import Dobro.Schema.OneOfBy, only: [defoneof_by: 3]

  defmodule CreateParams do
    defstruct [:resource]

    def new(%{} = input), do: {:ok, struct(__MODULE__, Map.take(input, [:resource]))}
    def load(%{} = input), do: new(input)
  end

  defmodule NotifyParams do
    defstruct [:notification_identifier]

    def new(%{} = input),
      do: {:ok, struct(__MODULE__, Map.take(input, [:notification_identifier]))}

    def load(%{} = input), do: new(input)
  end

  defoneof_by SampleParams, types: [CreateParams, NotifyParams], by: :action do
    def resolve(:create_resource), do: CreateParams
    def resolve(:send_notification), do: NotifyParams
    def resolve(_), do: nil
  end

  test "defoneof_by builds a OneOfBy module with resolve_type/1" do
    assert Dobro.Schema.OneOfBy.one_of_by?(SampleParams)
    refute Dobro.Schema.OneOf.one_of?(SampleParams)
    assert SampleParams.__one_of_by_types__() == [CreateParams, NotifyParams]
    assert SampleParams.__one_of_by_controller__() == :action
    assert SampleParams.resolve_type(:create_resource) == CreateParams
    assert SampleParams.resolve_type(:send_notification) == NotifyParams
    assert SampleParams.resolve_type(:unknown) == nil
    assert SampleParams.resolve_type(%CreateParams{resource: "x"}) == CreateParams
  end

  test "resolve_member reads the controller field from parent" do
    assert {:ok, CreateParams} =
             Dobro.Schema.OneOfBy.resolve_member(SampleParams, %{action: :create_resource})

    assert {:error, :could_not_resolve} =
             Dobro.Schema.OneOfBy.resolve_member(SampleParams, %{})
  end

  test "DomainValue.load uses parent controller field" do
    assert {:ok, %CreateParams{resource: "amount"}} =
             Dobro.Schema.DomainValue.load(%{resource: "amount"}, SampleParams, %{
               action: :create_resource
             })

    assert {:error, :could_not_resolve} =
             Dobro.Schema.DomainValue.load(%{resource: "amount"}, SampleParams, %{})
  end

  test "keyed_variants reuse OneOf member keys" do
    assert Dobro.Schema.OneOfBy.keyed_variants(SampleParams) == [
             create_params: CreateParams,
             notify_params: NotifyParams
           ]
  end
end
