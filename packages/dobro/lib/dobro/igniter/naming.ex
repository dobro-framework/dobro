defmodule Dobro.Igniter.Naming do
  @moduledoc false

  @doc """
  Parse `MyApp.Catalog.Products.Product` into BC and aggregate names.

  The aggregate module is placed under `BC.Domain.Name`.
  """
  def split_aggregate(module) when is_atom(module) do
    parts = Module.split(module)

    case parts do
      [] ->
        raise ArgumentError, "invalid module #{inspect(module)}"

      [_] ->
        raise ArgumentError,
              "aggregate module must be nested under a bounded context, got: #{inspect(module)}"

      parts ->
        aggregate = List.last(parts)
        bc_parts = Enum.drop(parts, -1)
        bc_module = Module.concat(bc_parts)
        aggregate_module = Module.concat([bc_module, Domain, aggregate])

        %{
          aggregate_module: aggregate_module,
          aggregate_name: aggregate,
          aggregate_atom: to_atom_name(aggregate),
          bc_module: bc_module,
          bc_parts: bc_parts,
          context_atom: context_atom(bc_parts),
          table: pluralize(Macro.underscore(aggregate)),
          singular: Macro.underscore(aggregate),
          list_name: Macro.camelize(pluralize(Macro.underscore(aggregate))),
          create_event: Module.concat([bc_module, Domain, Events, :"#{aggregate}Created"]),
          update_event: Module.concat([bc_module, Domain, Events, :"#{aggregate}Updated"]),
          delete_event: Module.concat([bc_module, Domain, Events, :"#{aggregate}Deleted"])
        }
    end
  end

  @doc false
  def pluralize(word) when is_binary(word) do
    cond do
      String.ends_with?(word, "y") and not String.ends_with?(word, ~w(ay ey iy oy uy)) ->
        String.replace_suffix(word, "y", "ies")

      String.ends_with?(word, ["s", "x", "z", "ch", "sh"]) ->
        word <> "es"

      true ->
        word <> "s"
    end
  end

  def context_atom(bc_parts) when is_list(bc_parts) do
    bc_parts
    |> Enum.drop(1)
    |> case do
      [] ->
        bc_parts
        |> List.last()
        |> Macro.underscore()
        |> String.to_atom()

      rest ->
        rest
        |> Enum.map_join("_", &Macro.underscore/1)
        |> String.to_atom()
    end
  end

  def parse_fields(nil), do: [{:name, :string}]
  def parse_fields(""), do: [{:name, :string}]

  def parse_fields(fields) when is_binary(fields) do
    fields
    |> String.split(",", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, ":", parts: 2) do
        [name, type] ->
          {String.to_atom(String.trim(name)), String.to_atom(String.trim(type))}

        [name] ->
          {String.to_atom(String.trim(name)), :string}
      end
    end)
  end

  def to_atom_name(name) when is_binary(name) do
    name |> Macro.underscore() |> String.to_atom()
  end

  def policy_read(context_atom), do: :"#{context_atom}/read"
  def policy_manage(context_atom), do: :"#{context_atom}/manage"

  def api_module(bc_module) do
    name = bc_module |> Module.split() |> List.last()
    Module.concat(bc_module, :"#{name}Api")
  end

  def port_api_module(bc_module) do
    name = bc_module |> Module.split() |> List.last()
    Module.concat([bc_module, Ports, :"#{name}Api"])
  end
end
