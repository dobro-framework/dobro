defmodule Dobro.App.Api.SurfaceTest do
  use ExUnit.Case, async: false

  alias Dobro.App.Api.Surface

  setup do
    previous = Application.get_env(:dobro, :api_surfaces, [])
    Application.put_env(:dobro, :api_surfaces, [])

    on_exit(fn ->
      Application.put_env(:dobro, :api_surfaces, previous)
    end)

    :ok
  end

  test "register/1 tracks known surfaces" do
    refute Surface.known?(:rules)
    assert :ok = Surface.register(:rules)
    assert Surface.known?(:rules)
    assert :rules in Surface.registered()
  end

  test "assert_registered!/1 raises for unknown surfaces" do
    assert_raise ArgumentError, ~r/unknown API surface :nope/, fn ->
      Surface.assert_registered!(:nope)
    end
  end

  test "apis/1, routes/1, and command_routes/1 require a registered surface" do
    assert_raise ArgumentError, ~r/unknown API surface :missing_surface/, fn ->
      Surface.apis(:missing_surface)
    end

    assert_raise ArgumentError, ~r/unknown API surface :missing_surface/, fn ->
      Surface.routes(:missing_surface)
    end

    assert_raise ArgumentError, ~r/unknown API surface :missing_surface/, fn ->
      Surface.command_routes(:missing_surface)
    end
  end
end
