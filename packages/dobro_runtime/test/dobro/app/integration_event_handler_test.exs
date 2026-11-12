defmodule Dobro.App.IntegrationEventHandlerTest do
  use ExUnit.Case, async: true

  defmodule Fixed do
    use Dobro.App.IntegrationEventHandler, patterns: ["sample.#"]
  end

  defmodule FromCatalog do
    use Dobro.App.IntegrationEventHandler, patterns: {__MODULE__, :sample}

    def sample, do: ["catalog.#"]
  end

  test "a list is the subscription" do
    assert Fixed.__integration_patterns__() == ["sample.#"]
  end

  test "a module and function are called when the patterns are read" do
    assert FromCatalog.__integration_patterns__() == ["catalog.#"]
  end
end
