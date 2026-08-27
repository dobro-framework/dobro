defmodule Dobro.App.Api.Middleware do
  @moduledoc """
  Middleware behaviour
  """

  alias Dobro.App.Api.Pipeline.PipelineContext
  alias Dobro.App.ExecutionContext

  @callback call(
              PipelineContext.t(),
              ExecutionContext.t(),
              term()
            ) :: term()

  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour Dobro.App.Api.Middleware
    end
  end
end
