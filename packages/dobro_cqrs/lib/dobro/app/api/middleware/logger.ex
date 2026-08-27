defmodule Dobro.App.Api.Middleware.Logger do
  @moduledoc """
  API Logger middleware
  """

  use Dobro.App.Api.Middleware

  require Logger

  def call(
        pipeline_context,
        execution_context,
        next
      ) do
    label = "#{pipeline_context.type}: #{inspect(pipeline_context.name)}"

    Logger.info("""
    #{label}
    Args: #{inspect(pipeline_context.args)}
    Policy: #{inspect(pipeline_context.policy)})
    Auth Context: #{inspect(execution_context.auth_context)}
    Tenant Context: #{inspect(execution_context.tenant)}
    """)

    result = next.()

    Logger.info("""
    #{label}
    Finished with result:
    #{inspect(result)}
    """)

    result
  end
end
