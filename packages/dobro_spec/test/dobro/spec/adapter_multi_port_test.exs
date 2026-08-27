defmodule Dobro.Spec.AdapterMultiPortTest do
  use ExUnit.Case, async: true

  defmodule ExamplePort do
    use Dobro.Spec.Port
  end

  defmodule OtherPort do
    use Dobro.Spec.Port
  end

  defmodule MultiPortAdapter do
    use Dobro.Spec.Adapter,
      ports: [ExamplePort, OtherPort],
      port_for: [{OtherPort, [tag: :other]}]
  end

  defmodule SinglePortAdapter do
    use Dobro.Spec.Adapter, port: ExamplePort
  end

  defmodule TestRegistry do
    use Dobro.Spec.AdapterRegistry

    register MultiPortAdapter
    register SinglePortAdapter
  end

  test "__ports__/0 lists all ports" do
    assert MultiPortAdapter.__ports__() == [ExamplePort, OtherPort]
    assert SinglePortAdapter.__ports__() == [ExamplePort]
  end

  test "register emits one entry per port with per-port for criteria" do
    entries = TestRegistry.registry()

    assert {ExamplePort, [], MultiPortAdapter} in entries
    assert {OtherPort, [tag: :other], MultiPortAdapter} in entries
    assert {ExamplePort, [], SinglePortAdapter} in entries
  end

  test "resolve_all filters Api.Port-style surface criteria" do
    defmodule SurfaceRegistry do
      use Dobro.Spec.AdapterRegistry

      register MultiPortAdapter
    end

    # MultiPortAdapter is not registered on Api.Port; surface filter returns empty.
    assert SurfaceRegistry.resolve_all(Dobro.App.Api.Port, surface: :graphql) == []
  end
end
