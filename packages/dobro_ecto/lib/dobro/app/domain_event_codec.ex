defmodule Dobro.App.DomainEventCodec do
  @moduledoc """
  Encodes and decodes domain event structs for storage and outbox relay.

  Encode deep-flattens nested structs via `Dobro.App.DataTransfer.DTO` so
  payloads are always JSON-safe maps.

  Decode rehydrates nested value objects when the event module defines a
  payload schema (`defevent` / `payload do`); otherwise atomizes keys into a
  plain map (legacy / ad-hoc event structs).
  """

  alias Dobro.App.DataTransfer.DTO
  alias Dobro.Domain.Messages.MessageIdentity
  alias Dobro.Pipeline
  alias Dobro.State

  @doc "Encodes a domain event struct to a JSON-friendly map."
  @spec encode(struct()) :: map()
  def encode(%{__struct__: _} = event) do
    %{
      "event_type" => event.__struct__ |> Atom.to_string(),
      "payload" => DTO.to_dto(Map.get(event, :payload)),
      "message_identity" => DTO.to_dto(Map.get(event, :message_identity)),
      "version" => Map.get(event, :version)
    }
  end

  @doc "Decodes a stored event map back to a domain event struct."
  @spec decode(map()) :: struct()
  def decode(%{"event_type" => event_type} = data) do
    module = event_type |> String.split(".") |> Module.safe_concat()
    Code.ensure_loaded!(module)

    struct(module, %{
      payload: decode_payload(module, data["payload"]),
      message_identity: decode_message_identity(data["message_identity"]),
      version: data["version"]
    })
  end

  defp decode_payload(event_module, raw) do
    input = atomize_keys(raw || %{})

    case payload_schema(event_module) do
      nil -> input
      payload_mod -> hydrate_payload(payload_mod, input)
    end
  end

  defp payload_schema(event_module) do
    with true <- function_exported?(event_module, :__schema__, 1),
         {payload_mod, _opts} when is_atom(payload_mod) <- event_module.__schema__(:payload),
         true <- Code.ensure_loaded?(payload_mod),
         true <- function_exported?(payload_mod, :__schema__, 0) do
      payload_mod
    else
      _ -> nil
    end
  end

  defp hydrate_payload(payload_mod, input) do
    pipeline =
      Pipeline.new(
        state: %{value: %{}},
        input: input,
        config: %{schema_module: payload_mod}
      )
      |> State.hydrate_all()

    case pipeline do
      %{errors: []} ->
        struct(payload_mod, pipeline.state.value)

      %{errors: errors} ->
        raise ArgumentError,
              "failed to hydrate event payload #{inspect(payload_mod)}: #{inspect(errors)}"
    end
  end

  defp decode_message_identity(nil), do: nil

  defp decode_message_identity(data) when is_map(data) do
    # Contract.normalize_input atomizes known fields safely (cold VMs may not
    # have :correlation_id etc. in the atom table until MessageIdentity loads).
    Code.ensure_loaded!(MessageIdentity)
    MessageIdentity.new!(data)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {atomize_key(key), atomize_keys(value)}
      {key, value} when is_atom(key) -> {key, atomize_keys(value)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp atomize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
