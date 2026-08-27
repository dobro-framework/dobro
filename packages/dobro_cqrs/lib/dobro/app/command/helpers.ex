defmodule Dobro.App.Command.Helpers do
  @moduledoc """
  Builds command structs from raw input maps.

  Used by the `Dobro.App.Command` macro to cast identity, payload, scope, and
  message identity fields.
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
         scope: resolve_scope(command_module, args),
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

  defp resolve_scope(command_module, args) do
    scope =
      if function_exported?(command_module, :__scope__, 0),
        do: command_module.__scope__(),
        else: nil

    case scope do
      {:tenant, :payload} ->
        cond do
          not is_nil(Map.get(args, :tenant_id)) ->
            {:tenant, args.tenant_id}

          is_binary(Map.get(args, :tenant_identifier)) and args.tenant_identifier != "" ->
            {:tenant, {:identifier, args.tenant_identifier}}

          true ->
            {:tenant, nil}
        end

      other ->
        other
    end
  end
end
