defmodule Dobro.Infra.Data.WriteRepo.Operation do
  @moduledoc """
  Resolves the WriteRepo operation from aggregate state and emitted events.
  """

  @delete_event_suffix "Deleted"

  @doc """
  Returns `:insert`, `:update`, or `:delete`.

  Delete events win even when the schema is already gone (e.g. a warm actor
  after a hard delete), so the delete strategy can return `:already_deleted`
  instead of accidentally inserting again.

  Insert when there is no persisted schema yet, or any identity field on the
  aggregate is nil.
  """
  @spec resolve(term(), [term()]) :: :insert | :update | :delete
  def resolve(%{aggregate: aggregate} = unit_of_work, events) do
    schema = Map.get(unit_of_work, :schema)

    cond do
      delete_event?(events) -> :delete
      is_nil(schema) or identity_unset?(aggregate) -> :insert
      true -> :update
    end
  end

  defp identity_unset?(%{__struct__: mod} = aggregate) do
    fields =
      if function_exported?(mod, :__identity_fields__, 0) do
        mod.__identity_fields__()
      else
        [:id]
      end

    Enum.any?(fields, fn field -> is_nil(Map.get(aggregate, field)) end)
  end

  defp identity_unset?(_), do: true

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
