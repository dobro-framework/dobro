defmodule Dobro.Infra.Data.WriteRepo.DeleteStrategy.EventOnly do
  @moduledoc """
  No-op delete for event-sourced aggregates whose state is projected elsewhere.

  The domain event is still emitted and broadcast; no state-persisted row is changed.
  """

  @behaviour Dobro.Infra.Data.WriteRepo.DeleteStrategy

  @impl Dobro.Infra.Data.WriteRepo.DeleteStrategy
  def delete(unit_of_work, _context, _opts), do: {:ok, unit_of_work}
end
