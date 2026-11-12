defmodule Dobro.App.IntegrationEventHandler do
  @moduledoc """
  Macro for a handler of public integration events.

  Omit `patterns:` to subscribe to every known topic. The supervisor reads
  that list when it starts. Pass a list, or `{module, function}`, for a
  narrower subscription. A handler that defines `__integration_patterns__/0`
  itself uses that list.

  `handle/1` clauses match the integration event map. A catch-all acknowledges
  events the handler does not care about.
  """

  defmacro __using__(opts \\ []) do
    patterns = patterns_ast(Keyword.get(opts, :patterns))

    quote do
      use Dobro.Spec.Adapter, port: Dobro.Ports.IntegrationEventHandler
      @before_compile Dobro.App.IntegrationEventHandler
      def __ack__, do: :with_work
      unquote(patterns)
    end
  end

  # `use` receives the option as AST. A list is the subscription. A
  # `{module, function}` pair is called when the supervisor reads it.
  defp patterns_ast(nil), do: nil

  defp patterns_ast({module, function}) do
    quote do
      def __integration_patterns__, do: unquote(module).unquote(function)()
    end
  end

  defp patterns_ast(patterns) when is_list(patterns) do
    quote do
      def __integration_patterns__, do: unquote(patterns)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def handle(_event), do: :ok
    end
  end
end
