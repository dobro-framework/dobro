defmodule Dobro.App.Command.Middleware do
  @moduledoc """
  Mutate-style middleware for the command-handler pipeline.

  Middleware modules implement `call/1` (and optionally `phase/0`). The
  command-handler pipeline invokes matching middleware at fixed phase call
  sites (`:before_contract`, `:after_contract`, `:before_execute`, `:after_execute`).
  """

  alias Dobro.Pipeline

  @type entry :: module() | {module(), keyword()}
  @type phase :: :before_contract | :after_contract | :before_execute | :after_execute

  @callback call(Pipeline.t()) :: Pipeline.t()
  @callback phase() :: phase()

  @optional_callbacks phase: 0

  @default_phase :before_contract

  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour Dobro.App.Command.Middleware

      def phase, do: unquote(@default_phase)

      defoverridable phase: 0
    end
  end

  @doc "Resolves the phase for a middleware entry."
  def phase_of(module) when is_atom(module) do
    if function_exported?(module, :phase, 0), do: module.phase(), else: @default_phase
  end

  def phase_of({module, opts}) when is_atom(module) and is_list(opts) do
    Keyword.get(opts, :phase, phase_of(module))
  end

  @doc "Builds a `(pipeline -> pipeline)` hook from a middleware entry."
  def to_hook(module) when is_atom(module) do
    &module.call/1
  end

  def to_hook({module, _opts}) when is_atom(module) do
    &module.call/1
  end

  @doc "Filters middleware entries for `phase` and runs them via `Dobro.Pipeline.run_hooks/2`."
  def run(pipeline, phase) when is_atom(phase) do
    hooks =
      pipeline
      |> middleware_entries()
      |> Enum.filter(&(phase_of(&1) == phase))
      |> Enum.map(&to_hook/1)

    Dobro.Pipeline.run_hooks(pipeline, hooks)
  end

  defp middleware_entries(%{config: %{middleware: entries}}) when is_list(entries), do: entries
  defp middleware_entries(_), do: []
end
