defmodule Dobro.App.Api.Port do
  @moduledoc """
  Introspection port for public API modules.

  Implemented automatically by modules using `Dobro.App.Api`.
  """

  use Dobro.Spec.Port

  @callback __queries__() :: keyword()
  @callback __queries__(atom()) :: {module(), keyword()} | nil
  @callback __commands__() :: keyword()
  @callback __commands__(atom()) :: {module(), keyword()} | nil
  @callback __context__() :: term()
end
