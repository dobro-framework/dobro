defmodule Dobro.Domain.Aggregate.HelpersTest do
  use ExUnit.Case, async: true

  alias Dobro.Domain.Aggregate.Helpers
  alias Dobro.Domain.Aggregate.HelpersTest.{Events, Widget}

  defmodule Events do
    use Dobro.Domain.EventDefinition

    defevent WidgetCreated do
      payload do
        field :id, :id
        field :name, :string
        field :source, :string
      end
    end

    defevent WidgetDeleted do
      payload do
        field :id, :id
        field :deleted_at, :datetime
      end
    end
  end

  defmodule Widget do
    use Dobro.Domain.Aggregate

    state do
      field :id, :id, immutable: true
      field :name, :string, required: true
    end

    defcontract Create do
      field :name, :string, required: true
    end

    defcontract Delete

    def create(%Create{} = input) do
      pipeline(input)
      |> add_event(Events.WidgetCreated, fn _widget, attrs ->
        Map.put(attrs, :source, "convention")
      end)
      |> apply_changes()
    end

    def delete(%__MODULE__{} = widget, %Delete{} = input) do
      widget
      |> pipeline(input)
      |> add_event(Events.WidgetDeleted, &with_deleted_at/2)
      |> apply_changes()
    end

    defapply Events.WidgetCreated
    defapply Events.WidgetDeleted
  end

  test "add_event/5 post-transform merges extra payload fields" do
    {:ok, input} = Widget.Create.new(%{name: "Alpha"})

    assert {:ok, %{value: widget, events: [event]}} = Widget.create(input)
    assert widget.name == "Alpha"
    assert event.payload.source == "convention"
  end

  test "with_deleted_at/2 adds deleted_at timestamp" do
    widget = %Widget{id: 1, name: "Alpha", version: 1}

    assert {:ok, %{events: [event]}} = Widget.delete(widget, %Widget.Delete{})
    assert %DateTime{} = event.payload.deleted_at
  end

  test "with_deleted_at/2 is exported from Helpers" do
    assert Helpers.with_deleted_at(%{}, %{id: 1})[:deleted_at]
  end
end
