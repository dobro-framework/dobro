defmodule Dobro.App.IntegrationEventPublisherTagTest do
  use ExUnit.Case, async: true

  defmodule Sample do
    use Dobro.App.IntegrationEventPublisher, topic: "sample"
  end

  test "the publisher macro tags the domain event handler" do
    assert Sample.__for__(Dobro.Ports.EventHandler) == [integration: true]
  end
end
