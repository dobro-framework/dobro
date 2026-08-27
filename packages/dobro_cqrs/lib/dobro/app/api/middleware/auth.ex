defmodule Dobro.App.Api.Middleware.Auth do
  @moduledoc """
  API Auth middleware
  """

  use Dobro.App.Api.Middleware

  require Logger
  alias Dobro.App.Api.Pipeline.PipelineContext
  alias Dobro.App.Auth.{AuthContext, SystemActor}
  alias Dobro.App.ExecutionContext

  #
  # Authorized if policy is public or if actor is present in auth_context
  #
  def call(
        %PipelineContext{policy: :public} = _pipeline_context,
        _context,
        next
      ) do
    Logger.info("Auth Middleware: Public policy, skipping authorization check.\n")

    next.()
  end

  def call(
        %PipelineContext{} = _pipeline_context,
        %ExecutionContext{
          auth_context: %AuthContext{actor: %SystemActor{type: type}} = _context
        },
        next
      )
      when is_atom(type) do
    Logger.info("Auth Middleware: Authorized as System Actor #{type}.\n")

    next.()
  end

  def call(
        %PipelineContext{} = _pipeline_context,
        %ExecutionContext{auth_context: %AuthContext{actor: %{id: id, type: type}} = _context},
        next
      )
      when is_integer(id) do
    Logger.info("Auth Middleware: Authorized as #{type} ID #{id}.\n")

    next.()
  end

  def call(pipeline_context, context, _next) do
    Logger.warning("""
    Auth Middleware: Not authorized.
    #{pipeline_context.type}: #{inspect(pipeline_context.name)}
    Execution context: #{inspect(context)}
    """)

    {:error, :not_authorized}
  end
end
