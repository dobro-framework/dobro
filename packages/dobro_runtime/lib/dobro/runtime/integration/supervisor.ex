defmodule Dobro.Runtime.Integration.Supervisor do
  @moduledoc """
  Starts one poller per integration pattern subscription.

  The transport module is `config :dobro_runtime, :integration_transport`.
  The Postgres transport is the default.
  """

  use Supervisor

  alias Dobro.Ports.IntegrationEventHandler

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children =
      IntegrationEventHandler.all()
      |> Enum.flat_map(&pattern_children/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Patterns this handler subscribes to.

  A handler with no `__integration_patterns__/0` subscribes to every topic
  prefix known at startup.
  """
  def patterns(handler) do
    Code.ensure_loaded(handler)

    if function_exported?(handler, :__integration_patterns__, 0) do
      handler.__integration_patterns__()
    else
      Dobro.Integration.prefixes()
    end
  end

  defp pattern_children(handler) do
    Enum.map(patterns(handler), fn pattern ->
      Supervisor.child_spec(
        {Dobro.Runtime.Integration.Poller, [handler: handler, pattern: pattern]},
        id: {Dobro.Runtime.Integration.Poller, handler, pattern}
      )
    end)
  end
end
