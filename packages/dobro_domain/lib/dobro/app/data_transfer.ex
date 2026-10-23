defmodule Dobro.App.DataTransfer do
  @moduledoc """
  Provides a DTO protocol to convert structs to DTOs
  """
  defprotocol DTO do
    @fallback_to_any true
    @spec to_dto(term()) :: term()
    def to_dto(data)
  end

  defimpl DTO, for: Any do
    def to_dto(%_{} = struct) do
      struct
      |> Map.from_struct()
      |> Map.delete(:__meta__)
      |> Enum.into(%{}, fn {k, v} -> {k, DTO.to_dto(v)} end)
    end

    def to_dto(list) when is_list(list),
      do: Enum.map(list, &DTO.to_dto/1)

    def to_dto(map) when is_map(map) do
      Enum.into(map, %{}, fn {k, v} -> {k, DTO.to_dto(v)} end)
    end

    def to_dto(other), do: other
  end

  defimpl DTO, for: Date do
    # Keep calendar dates intact. The Any impl would Map.from_struct/1 them into
    # %{year:, month:, day:, calendar:}, which Types.Date.new/1 rejects as nil.
    def to_dto(%Date{} = value), do: value
  end

  defimpl DTO, for: Time do
    def to_dto(%Time{} = value), do: value
  end

  defimpl DTO, for: NaiveDateTime do
    def to_dto(%NaiveDateTime{} = value) do
      DateTime.from_naive!(value, "Etc/UTC")
    end
  end

  defimpl DTO, for: DateTime do
    def to_dto(%DateTime{} = value), do: value
  end
end
