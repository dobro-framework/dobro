defmodule Dobro.App.Command.Helpers do
  @moduledoc """
  Builds command structs from raw input maps.

  Used by the `Dobro.App.Command` macro to cast identity, payload, and message
  identity fields.
  """

  alias Dobro.App.{Id, Messages.MessageIdentity}

  @doc "Constructs a command struct for `command_module` from `args`."
  def new(command_module, %{} = args) do
    with {:ok, identity} <- cast_part(identity_module(command_module), args),
         {:ok, payload} <- cast_part(payload_module(command_module), args) do
      id = Id.generate()

      {:ok,
       struct!(command_module, %{
         identity: identity,
         payload: payload,
         message_identity: MessageIdentity.new!(%{id: id, correlation_id: id, causation_id: id})
       })}
    end
  end

  defp identity_module(command_module) do
    if function_exported?(command_module, :__identity__, 0),
      do: command_module.__identity__(),
      else: nil
  end

  defp payload_module(command_module) do
    if function_exported?(command_module, :__payload__, 0),
      do: command_module.__payload__(),
      else: nil
  end

  defp cast_part(nil, _args), do: {:ok, nil}

  defp cast_part(module, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, :new, 1),
      do: module.new(args),
      else: {:ok, nil}
  end
end
