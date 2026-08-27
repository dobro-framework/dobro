defmodule Dobro.Infra.Data.Query.Spec do
  @moduledoc """
  Compiled specification for a read-repository query definition.
  """

  @enforce_keys [:module, :type, :schema]
  defstruct [
    :module,
    :repo,
    :type,
    :schema,
    :id_field,
    :root_binding,
    :query,
    fields: %{},
    joins: [],
    filterable: MapSet.new(),
    sortable: MapSet.new(),
    default_limit: 10,
    default_order: [],
    count: :exact,
    preloads: [],
    include_global: nil
  ]

  @type field_source ::
          {:column, binding :: atom(), field :: atom()}
          | {:join, join :: atom(), field :: atom()}
          | {:expr, Ecto.Query.DynamicExpr.t() | {module(), atom()}}

  @doc """
  Resolves an `expr` field source to an `Ecto.Query.DynamicExpr`.

  Compiled `defquery` fields store `{module, fun}` MFA tuples (so dynamics can be
  defined as module functions). Hand-built specs may store a `DynamicExpr` directly.
  """
  def resolve_expr(%Ecto.Query.DynamicExpr{} = expr), do: expr

  def resolve_expr({mod, fun}) when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [])
  end

  @type join_spec :: %{
          required(:name) => atom(),
          required(:assoc) => atom(),
          required(:schema) => module(),
          required(:source) => atom(),
          required(:type) => :inner | :left | :right | :full,
          required(:on) => {atom(), atom(), atom(), atom()}
        }

  @type preload :: %{
          required(:name) => atom(),
          required(:schema) => module(),
          optional(:fields) => [atom()] | nil,
          optional(:preloads) => [preload()]
        }

  @type t :: %__MODULE__{
          module: module(),
          repo: module(),
          type: :one | :list | :exists,
          schema: module(),
          id_field: atom() | nil,
          root_binding: atom() | nil,
          query: {module(), atom(), 2} | nil,
          fields: %{atom() => field_source()},
          joins: [join_spec()],
          filterable: MapSet.t(),
          sortable: MapSet.t(),
          default_limit: pos_integer(),
          default_order: [{direction :: :asc | :desc, field :: atom()}],
          count: :exact | :estimated | :skip,
          preloads: [preload()],
          include_global: boolean() | nil
        }

  @doc """
  Infers the root Ecto binding from a schema module name, e.g. `MappingSchema` → `:mapping`.
  """
  def infer_root_binding(schema_module) do
    schema_module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.replace_suffix("_schema", "")
    |> String.to_atom()
  end

  @doc """
  Returns joins required for `fields`, including transitive `through` dependencies, in definition order.
  """
  def joins_for_fields(%__MODULE__{} = spec, fields) when is_list(fields) or is_struct(fields, MapSet) do
    needed =
      fields
      |> Enum.reduce(MapSet.new(), fn field, acc ->
        case Map.get(spec.fields, field) do
          {:join, join, _} -> MapSet.put(acc, join)
          _ -> acc
        end
      end)

    needed
    |> MapSet.to_list()
    |> Enum.flat_map(&dependency_chain(spec, &1))
    |> Enum.uniq()
    |> then(fn join_names ->
      needed_set = MapSet.new(join_names)
      Enum.filter(spec.joins, &(&1.name in needed_set))
    end)
  end

  defp dependency_chain(%__MODULE__{} = spec, join_name) do
    join = fetch_join!(spec, join_name)

    if join.source == spec.root_binding do
      [join_name]
    else
      dependency_chain(spec, join.source) ++ [join_name]
    end
  end

  defp fetch_join!(spec, join_name) do
    case Enum.find(spec.joins, &(&1.name == join_name)) do
      nil -> raise ArgumentError, "join #{inspect(join_name)} is not defined on query spec"
      join -> join
    end
  end
end
