defmodule Dobro.State.OneOfByTest do
  use ExUnit.Case, async: true
  import Dobro.Enum, only: [defenum: 2]

  defmodule CreateParams do
    use Dobro.Schema

    schema do
      field :resource, :string, required: true
    end

    def new(value), do: Dobro.Contract.Helpers.new(__MODULE__, value)
  end

  defmodule NotifyParams do
    use Dobro.Schema

    schema do
      field :notification_identifier, :string, required: true
    end

    def new(value), do: Dobro.Contract.Helpers.new(__MODULE__, value)
  end

  defenum ActionKind do
    value :create_resource
    value :send_notification
  end

  defmodule ActionParams do
    use Dobro.Schema.OneOfBy,
      types: [CreateParams, NotifyParams],
      by: :action,
      resolve: &__MODULE__.resolve/1

    def resolve(:create_resource), do: CreateParams
    def resolve(:send_notification), do: NotifyParams
    def resolve(_), do: nil
  end

  defmodule Envelope do
    use Dobro.Schema

    schema do
      field :action, ActionKind, required: true
      field :params, ActionParams, required: true
    end

    def new(value), do: Dobro.Contract.Helpers.new(__MODULE__, value)
  end

  test "casts params using sibling action field" do
    assert {:ok, %Envelope{action: :create_resource, params: %CreateParams{resource: "x"}}} =
             Envelope.new(%{action: :create_resource, params: %{resource: "x"}})
  end

  test "casts keyed exclusive envelope using sibling action" do
    assert {:ok, %Envelope{params: %NotifyParams{notification_identifier: "n1"}}} =
             Envelope.new(%{
               action: :send_notification,
               params: %{notify_params: %{notification_identifier: "n1"}}
             })
  end

  test "rejects when action does not resolve a member" do
    assert {:error, _errors} = Envelope.new(%{action: nil, params: %{resource: "x"}})
  end
end
