defmodule Dobro.App.ExecutionContext do
  @moduledoc """
  ExecutionContext holds context information for executing use cases
  """

  use TypedStruct

  alias Dobro.App.Auth.{AuthContext, TenantContext}
  alias Dobro.App.Selection

  typedstruct do
    field :auth_context, AuthContext.t(), default: nil
    field :tenant, TenantContext.t(), default: nil
    field :selection, Selection.t(), default: nil
  end

  def new(%__MODULE__{} = context), do: context

  def new(attrs) do
    struct(__MODULE__, attrs)
  end

  def fetch(struct, key) do
    Map.fetch(Map.from_struct(struct), key)
  end
end
