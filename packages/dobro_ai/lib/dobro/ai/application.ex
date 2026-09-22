defmodule Dobro.AI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Dobro.App.Api.Surface.register(:ai)

    :ok = :application.set_env(:dobro, :api_surfaces, [:ai])

    Supervisor.start_link([], strategy: :one_for_one, name: Dobro.AI.Supervisor)
  end
end
