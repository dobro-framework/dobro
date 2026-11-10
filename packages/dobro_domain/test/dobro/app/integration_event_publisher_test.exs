defmodule Dobro.App.IntegrationEventPublisherTest do
  use ExUnit.Case, async: true

  defmodule WidgetCreated do
    defstruct [:payload, :message_identity]
  end

  test "build produces snake_case event_name and BC topic" do
    event = %WidgetCreated{
      payload: %{id: 7, tenant_id: 1},
      message_identity: %{id: "evt-1"}
    }

    built =
      Dobro.App.IntegrationEventPublisher.build(
        event,
        [stream_name: "Widget", subject_id: :id],
        [topic: "widgets", subject_type: "widget"],
        fn e -> %{id: e.id, tenant_id: e.tenant_id} end
      )

    assert built.topic == "widgets"
    assert built.event_name == "widget_created"
    assert built.subject_type == "widget"
    assert built.subject_id == 7
    assert built.payload == %{id: 7, tenant_id: 1}
  end

  test "name override replaces the default event name" do
    event = %WidgetCreated{
      payload: %{id: 7},
      message_identity: %{id: "evt-2"}
    }

    built =
      Dobro.App.IntegrationEventPublisher.build(
        event,
        [stream_name: "Widget", subject_id: :id, name: "renamed"],
        [topic: "widgets", subject_type: "widget"],
        fn e -> %{id: e.id} end
      )

    assert built.event_name == "renamed"
  end

  test "enum atoms in the public payload are stored as strings" do
    event = %WidgetCreated{
      payload: %{id: 7, author_user_id: 3},
      message_identity: %{id: "evt-3"}
    }

    built =
      Dobro.App.IntegrationEventPublisher.build(
        event,
        [stream_name: "Widget", subject_id: :id],
        [topic: "widgets", subject_type: "widget"],
        fn _e ->
          %{
            status: :active,
            next_of_kin_is: nil,
            flagged: true,
            skipped: false,
            tags: [:draft, :open],
            original: %{status: :closed, note: "kept"}
          }
        end
      )

    assert built.payload == %{
             status: "active",
             next_of_kin_is: nil,
             flagged: true,
             skipped: false,
             tags: ["draft", "open"],
             original: %{status: "closed", note: "kept"},
             author_user_id: 3
           }
  end
end
