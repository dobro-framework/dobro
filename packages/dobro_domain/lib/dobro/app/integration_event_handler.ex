defmodule Dobro.App.IntegrationEventHandler do
  @moduledoc """
  Macro for a handler of public integration events.

  Pass `patterns:` for a fixed subscription list. Omit it when the handler
  defines `__integration_patterns__/0` itself, for example by reading
  configuration at startup.

  `handle/1` clauses match the integration event map. A catch-all acknowledges
  events the handler does not care about.
  """

  defmacro __using__(opts \\ []) do
    patterns = Keyword.get(opts, :patterns)

    patterns_ast =
      if is_nil(patterns) do
        quote do: nil
      else
        quote do
          def __integration_patterns__, do: unquote(patterns)
        end
      end

    quote do
      use Dobro.Spec.Adapter, port: Dobro.Ports.IntegrationEventHandler
      @before_compile Dobro.App.IntegrationEventHandler
      def __ack__, do: :with_work
      unquote(patterns_ast)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def handle(_event), do: :ok
    end
  end
end
