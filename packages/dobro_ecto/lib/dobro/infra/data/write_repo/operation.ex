defmodule Dobro.Infra.Data.WriteRepo.Operation do
  @moduledoc """
  Resolves the WriteRepo operation from aggregate state and emitted events.
  """

  @delete_event_suffix "Deleted"

  @doc """
  Returns `:insert`, `:update`, or `:delete`.
  """
  @spec resolve(term(), [term()]) :: :insert | :update | :delete
  def resolve(%{aggregate: aggregate}, events) do
    cond do
      is_nil(aggregate.id) -> :insert
      delete_event?(events) -> :delete
      true -> :update
    end
  end

  @doc "Returns true when the event struct name ends with `Deleted`."
  @spec delete_event?(term()) :: boolean()
  def delete_event?(events) when is_list(events), do: Enum.any?(events, &delete_event?/1)

  def delete_event?(%{__struct__: module}) do
    module
    |> Module.split()
    |> List.last()
    |> String.ends_with?(@delete_event_suffix)
  end

  def delete_event?(_), do: false
end
