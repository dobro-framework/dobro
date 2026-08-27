defmodule Dobro.App.HandlerResult do
  @moduledoc """
  Normalised success and failure envelope returned by command and query handlers.

  Payloads are converted to DTOs on success; failures carry a list of errors.
  """
  use TypedStruct

  alias Dobro.App.DataTransfer.DTO

  typedstruct do
    field :payload, term()
    field :errors, [term()], default: []
  end

  @doc "Wraps a successful handler payload as `{:ok, %HandlerResult{}}`."
  def success(payload) do
    {:ok, %__MODULE__{payload: DTO.to_dto(payload)}}
  end

  @doc "Wraps a pipeline or error list as `{:error, %HandlerResult{}}`."
  def failure(%{errors: errors}) do
    {:error, %__MODULE__{errors: errors || []}}
  end

  def failure(errors) do
    {:error, %__MODULE__{errors: errors || []}}
  end
end
