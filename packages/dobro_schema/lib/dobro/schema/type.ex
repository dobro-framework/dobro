defmodule Dobro.Schema.Type do
  @moduledoc """
  Behaviour for Dobro schema field types (primitives and custom).

  Built-in implementations live under `Dobro.Schema.Types` and are registered
  by atom (`:string`, `:any`, …). A custom type is any module that implements
  this behaviour; use the module itself as the field type.

      field :payload, MyApp.OpaquePayload

  ## Callbacks

  - `new/1` — coerce a raw input value into the typed representation
  - `validate/2` — run a single validator (`:presence`, `{:format, regex}`, …)
  """

  @type validator :: atom() | {atom(), term()}

  @callback new(term()) :: term()
  @callback validate(term(), validator()) :: :ok | {:error, atom()}
end
