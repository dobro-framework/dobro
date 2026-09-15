defmodule Dobro.App.EventHandler do
  @moduledoc """
  Macro for defining an event handler.

  Options:

  - `:stream_name` (required) — PubSub stream to subscribe to
  - `:consumer_mode` — `:singleton` (default) or `:every_node`
  """
  defmacro __using__(opts \\ []) do
    stream_name = Keyword.fetch!(opts, :stream_name)
    consumer_mode = Keyword.get(opts, :consumer_mode)

    quote do
      use Dobro.Spec.Adapter, port: Dobro.Ports.EventHandler
      @before_compile Dobro.App.EventHandler
      @stream_name unquote(stream_name)
      @consumer_mode unquote(consumer_mode)
    end
  end

  defmacro __before_compile__(_) do
    quote do
      def handle(_), do: :ok
      def __stream_name__, do: @stream_name

      def __consumer_mode__ do
        @consumer_mode || Application.get_env(:dobro_runtime, :event_consumer_mode, :singleton)
      end
    end
  end
end
