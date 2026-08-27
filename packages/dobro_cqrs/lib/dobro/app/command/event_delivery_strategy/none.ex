defmodule Dobro.App.Command.EventDeliveryStrategy.None do
  @moduledoc """
  No-op event delivery strategy.

  Domain events are persisted but not published to downstream consumers.
  """

  @behaviour Dobro.App.Command.EventDeliveryStrategy

  @impl true
  def stage(_events, _context, _opts), do: :ok

  @impl true
  def deliver(_events, _context, _opts), do: :ok

  @impl true
  def transactional_stage?, do: false
end
