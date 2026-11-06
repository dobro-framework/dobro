defmodule Dobro.IntegrationTest do
  use ExUnit.Case, async: false

  defmodule SamplePublisher do
    def __integration_events__ do
      [
        %{
          routing_key: "sample.created",
          subject_type: "thing",
          stream_name: "Thing",
          topic: "sample",
          event_name: "created"
        }
      ]
    end
  end

  setup do
    previous = Application.get_env(:dobro_spec, :adapter_registry)
    Application.put_env(:dobro_spec, :adapter_registry, __MODULE__.Registry)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:dobro_spec, :adapter_registry, previous),
        else: Application.delete_env(:dobro_spec, :adapter_registry)
    end)

    :ok
  end

  defmodule Registry do
    def resolve_all(Dobro.Ports.EventHandler), do: [Dobro.IntegrationTest.SamplePublisher]
    def resolve_all(_), do: []
  end

  test "catalog and prefixes come from publisher integration events" do
    assert [%{routing_key: "sample.created", topic: "sample", event_name: "created"}] =
             Dobro.Integration.catalog()

    assert Dobro.Integration.prefixes() == ["sample.#"]
  end
end
