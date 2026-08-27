defmodule Dobro.App.DomainEventCodec do
  @moduledoc """
  Encodes and decodes domain event structs for storage and outbox relay.
  """

  alias Dobro.Domain.Messages.MessageIdentity

  @doc "Encodes a domain event struct to a JSON-friendly map."
  @spec encode(struct()) :: map()
  def encode(%{__struct__: _} = event) do
    %{
      "event_type" => event.__struct__ |> Atom.to_string(),
      "payload" => to_map(Map.get(event, :payload)),
      "message_identity" => to_map(Map.get(event, :message_identity)),
      "version" => Map.get(event, :version)
    }
  end

  @doc "Decodes a stored event map back to a domain event struct."
  @spec decode(map()) :: struct()
  def decode(%{"event_type" => event_type} = data) do
    module = event_type |> String.split(".") |> Module.safe_concat()

    struct(module, %{
      payload: atomize_keys(data["payload"] || %{}),
      message_identity: decode_message_identity(data["message_identity"]),
      version: data["version"]
    })
  end

  defp decode_message_identity(nil), do: nil

  defp decode_message_identity(data) when is_map(data) do
    MessageIdentity.new!(atomize_keys(data))
  end

  defp to_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp to_map(map) when is_map(map), do: map
  defp to_map(other), do: other

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), atomize_keys(value)}
      {key, value} when is_atom(key) -> {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value
end
