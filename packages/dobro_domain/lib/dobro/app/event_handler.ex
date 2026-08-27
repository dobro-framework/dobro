defmodule Dobro.App.EventHandler do
  @moduledoc """
  Macro for defining an event handler
  """
  defmacro __using__(opts \\ []) do
    stream_name = Keyword.fetch!(opts, :stream_name)

    quote do
      use Dobro.Spec.Adapter, port: Dobro.Ports.EventHandler
      @before_compile Dobro.App.EventHandler
      @stream_name unquote(stream_name)
    end
  end

  defmacro __before_compile__(_) do
    quote do
      def handle(_), do: :ok
      def __stream_name__, do: @stream_name
    end
  end
end
