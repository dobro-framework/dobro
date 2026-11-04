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

  test "__identity_fields__/0 defaults to [:id]" do
    assert Widget.__identity_fields__() == [:id]
  end

  defmodule UuidEvents do
    use Dobro.Domain.EventDefinition

    defevent UuidWidgetCreated do
      payload do
        field :uuid, :id
        field :name, :string
      end
    end
  end

  defmodule UuidWidget do
    use Dobro.Domain.Aggregate

    identity do
      field :uuid, :id
    end

    state do
      field :name, :string, required: true
    end

    defcontract Create do
      field :name, :string, required: true
    end

    def create(%Create{} = input) do
      pipeline(input)
      |> add_event(UuidEvents.UuidWidgetCreated)
      |> apply_changes()
    end

    def create(%__MODULE__{} = widget, %Create{} = input) do
      pipeline(widget, input)
      |> add_event(UuidEvents.UuidWidgetCreated)
      |> apply_changes()
    end

    defapply UuidEvents.UuidWidgetCreated
  end

  test "identity do injects custom field and copies it into event payloads" do
    assert UuidWidget.__identity_fields__() == [:uuid]
    assert :uuid in UuidWidget.__fields__()
    refute :id in UuidWidget.__fields__()

    seeded = struct(UuidWidget, uuid: 42, version: 0)
    {:ok, input} = UuidWidget.Create.new(%{name: "Beta"})
    assert {:ok, %{value: widget, events: [event]}} = UuidWidget.create(seeded, input)
    assert widget.uuid == 42
    assert event.payload.uuid == 42
  end

  defmodule UpdateEvents do
    use Dobro.Domain.EventDefinition

    defevent WidgetDetailsUpdated do
      payload do
        field :id, :id
        field :name, :string
        field :colour, :string
      end
    end
  end

  defmodule UpdatableWidget do
    use Dobro.Domain.Aggregate
    import Dobro.State

    state do
      field :name, :string, required: true
      field :colour, :string
    end

    defcontract Update do
      field :name, :string
      field :colour, :string
    end

    def update(%__MODULE__{} = widget, %Update{} = input) do
      widget
      |> pipeline(input)
      |> add_event(UpdateEvents.WidgetDetailsUpdated,
        if: changed?([:name, :colour])
      )
      |> apply_changes()
    end

    defapply UpdateEvents.WidgetDetailsUpdated, [:name, :colour]
  end

  test "changed?/1 with a field list emits when any listed field differs" do
    widget = %UpdatableWidget{id: 1, name: "Alpha", colour: "red", version: 1}

    {:ok, same} = UpdatableWidget.Update.new(%{name: "Alpha", colour: "red"})
    assert {:ok, %{events: []}} = UpdatableWidget.update(widget, same)

    {:ok, colour_only} = UpdatableWidget.Update.new(%{name: "Alpha", colour: "blue"})
    assert {:ok, %{value: updated, events: [event]}} =
             UpdatableWidget.update(widget, colour_only)

    assert updated.colour == "blue"
    assert event.payload.colour == "blue"
  end

  test "put_in_workspace/3 and get_from_workspace/2 round-trip" do
    pipeline = Widget.pipeline(%Widget.Create{name: "Alpha"})
    pipeline = Widget.put_in_workspace(pipeline, :note, "hello")

    assert Widget.get_from_workspace(pipeline, :note) == "hello"
  end

  defmodule WorkspaceEvents do
    use Dobro.Domain.EventDefinition

    defevent WidgetNoted do
      payload do
        field :id, :id
        field :name, :string
        field :note, :string
      end
    end
  end

  defmodule WorkspaceWidget do
    use Dobro.Domain.Aggregate

    state do
      field :name, :string, required: true
    end

    defcontract Note do
      field :name, :string
    end

    def note(%__MODULE__{} = widget, %Note{} = input) do
      widget
      |> pipeline(input)
      |> step(fn pipeline ->
        {:ok, put_in_workspace(pipeline, :note, "from-workspace")}
      end)
      |> add_event(&widget_noted/1)
      |> apply_changes()
    end

    defapply WorkspaceEvents.WidgetNoted, [:name]

    defp widget_noted(
           %{state: %{value: widget, workspace: %{note: note}}, input: input}
         ) do
      WorkspaceEvents.WidgetNoted.new(%{
        payload: %{
          id: widget.id,
          name: input.name || widget.name,
          note: note
        }
      })
    end
  end

  test "1-arity add_event builder can read workspace" do
    widget = %WorkspaceWidget{id: 1, name: "Alpha", version: 1}
    {:ok, input} = WorkspaceWidget.Note.new(%{name: "Beta"})

    assert {:ok, %{value: updated, events: [event]}} = WorkspaceWidget.note(widget, input)
    assert updated.name == "Beta"
    assert event.payload.note == "from-workspace"
  end
end
