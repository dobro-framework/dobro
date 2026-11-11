defmodule Dobro.App.Api.Middleware.Tenant do
  @moduledoc """
  Rejects a call whose tenant context is illegal for the route's surfaces.

  Nil is an error on GraphQL routes. `%GlobalContext{}` is allowed on
  `:admin_graphql` routes and on internal routes that have no GraphQL surface.
  A tenant-only route rejects it. Internal lookups may also run with a nil tenant.
  """

  use Dobro.App.Api.Middleware

  alias Dobro.App.Api.Pipeline.PipelineContext
  alias Dobro.App.Auth.GlobalContext
  alias Dobro.App.ExecutionContext
  alias Dobro.Error

  def call(
        %PipelineContext{surfaces: surfaces},
        %ExecutionContext{tenant: tenant},
        next
      ) do
    surfaces = List.wrap(surfaces)

    cond do
      is_nil(tenant) and graphql_route?(surfaces) ->
        {:error, tenant_required()}

      match?(%GlobalContext{}, tenant) and graphql_route?(surfaces) and
          :admin_graphql not in surfaces ->
        {:error, tenant_required()}

      true ->
        next.()
    end
  end

  def call(_pipeline_context, _context, next), do: next.()

  defp graphql_route?(surfaces) do
    :tenant_graphql in surfaces or :admin_graphql in surfaces
  end

  defp tenant_required do
    Error.new(:tenant_required, description: "Tenant context is required")
  end
end
