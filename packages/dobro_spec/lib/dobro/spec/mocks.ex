defmodule Dobro.Spec.Mocks do
  @moduledoc """
  Generates and registers Mox mocks for every port in the configured adapter registry.

  Use via `use Dobro.Spec.Mocks` in test support. Call `register_all/0` at
  runtime to point application config at the generated mock modules.
  """

  @doc "Defines Mox mocks for all registered ports."
  defmacro __using__(_opts \\ []) do
    registry = Dobro.Config.adapter_registry!().registry()

    ports =
      registry
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.reject(&(&1 == Dobro.App.Api.Port))

    mocks =
      for port <- ports do
        mock = Module.concat(port, Mock)

        quote do
          require Mox
          Mox.defmock(unquote(mock), for: unquote(port))
        end
      end

    quote do
      (unquote_splicing(mocks))
    end
  end

  @doc "Points application config at each port's mock module."
  def register_all do
    otp_app = Dobro.Config.otp_app()

    Dobro.Config.adapter_registry!().registry()
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == Dobro.App.Api.Port))
    |> Enum.each(fn port ->
      mock = Module.concat(port, Mock)
      _ = Code.ensure_compiled!(mock)
      Application.put_env(otp_app, port, mock)
    end)
  end
end
