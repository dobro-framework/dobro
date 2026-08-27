defmodule Dobro.Graphql.Schema.MutationBuilder do
  @moduledoc """
  Resolves command metadata and GraphQL naming for `api_mutation/2` macros.
  """

  alias Dobro.App.Api
  alias Dobro.Graphql.Schema

  @doc "Returns command, payload, identity, result modules and scope for a mutation."
  def command_modules(api_module, command_fn) do
    {command_module, opts} = api_module.__commands__(command_fn)
    Code.ensure_compiled!(command_module)

    payload_module =
      if function_exported?(command_module, :__payload__, 0),
        do: command_module.__payload__(),
        else: nil

    identity_module =
      if function_exported?(command_module, :__identity__, 0),
        do: command_module.__identity__(),
        else: nil

    result_module = Api.mutation_result_module(api_module, command_fn, opts)

    %{
      command_module: command_module,
      payload_module: payload_module,
      identity_module: identity_module,
      result_module: result_module,
      scope: command_module.__scope__()
    }
  end

  @doc "Derives GraphQL type and field names for a mutation."
  def names(api_module, command_module, _result_module, context_map) do
    api_namespace = Schema.namespace_for(api_module, context_map)
    command_namespace = Schema.namespace_for(command_module, context_map)
    command_name = Schema.name_from_module(command_module)

    %{
      field_name: Schema.name_for([api_namespace, command_name]),
      input_name: Schema.name_for([command_namespace, command_name, "input"]),
      result_name: Schema.name_for([command_namespace, command_name, "result"]),
      payload_name: Schema.name_for([command_namespace, command_name, "payload"])
    }
  end

  @doc "Returns an Absinthe field block for tenant-scoped mutations, if required."
  def scope_block({scope_name, scope_from}) do
    if scope_name == :tenant and scope_from == :payload do
      quote do
        field(:tenant_id, non_null(:id))
      end
    end
  end
end
