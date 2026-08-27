defmodule Dobro.Query do
  @moduledoc """
  Helper module for validating and running queries
  """

  import Ecto.Query

  alias Dobro.Query.List, as: ListQuery
  alias Dobro.Query.Params
  alias Dobro.Infra.Data.Query.Spec

  @doc """
  Filters a query to records where `field` equals `value`.

  When `value` is nil, uses `IS NULL` instead of `= NULL`, which Ecto/SQL cannot
  match correctly with a plain `== ^value` expression.
  """
  def where_eq(queryable, field, value) when is_atom(field) do
    if is_nil(value) do
      from q in queryable, where: is_nil(field(q, ^field))
    else
      from q in queryable, where: field(q, ^field) == ^value
    end
  end

  @doc """
  Validates and runs the given queryable and params using the list query runner.

  For read repositories using `defquery`, prefer `Dobro.Infra.Data.Query.Runner`.
  """
  def validate_and_run(queryable, params, opts \\ []) do
    spec = simple_list_spec(Keyword.fetch!(opts, :for), opts)
    selection = Keyword.get(opts, :selection)

    ListQuery.run(queryable, params, spec, selection: selection)
  end

  defp simple_list_spec(schema_module, opts) do
    %Dobro.Infra.Data.Query.Spec{
      module: :default,
      repo: nil,
      type: :list,
      schema: schema_module,
      root_binding: Spec.infer_root_binding(schema_module),
      fields: simple_fields(schema_module),
      joins: [],
      filterable: MapSet.new(Keyword.get(opts, :filterable, default_filterable(schema_module))),
      sortable: MapSet.new(Keyword.get(opts, :sortable, default_sortable(schema_module))),
      default_limit: Keyword.get(opts, :default_limit, 10)
    }
  end

  defp simple_fields(schema_module) do
    schema_module.__schema__(:fields)
    |> Kernel.--(schema_module.__schema__(:embeds))
    |> Enum.reject(&(&1 in [:version, :inserted_at, :updated_at, :created_at]))
    |> Map.new(fn field -> {field, {:column, Spec.infer_root_binding(schema_module), field}} end)
  end

  defp default_filterable(schema_module) do
    case schema_module.__info__(:attributes) do
      attributes ->
        case Keyword.get(attributes, :list_filterable, []) do
          [] -> schema_fields(schema_module) -- [:id]
          fields -> fields
        end
    end
  end

  defp default_sortable(schema_module) do
    case schema_module.__info__(:attributes) do
      attributes ->
        case Keyword.get(attributes, :list_sortable, []) do
          [] -> schema_fields(schema_module)
          fields -> fields
        end
    end
  end

  defp schema_fields(schema_module) do
    schema_module.__schema__(:fields) -- schema_module.__schema__(:embeds)
  end

  defmodule Tenant do
    @moduledoc """
    A helper module to apply tenant override logic to Ecto queries.
    This module provides a function to modify queries to include records
    that either belong to a specific tenant or are global (i.e., have no tenant_id),
    while ensuring that global records are only included if there is no tenant-specific
    record with the same identifier.
    """

    import Ecto.Query

    defmodule MissingTenantError do
      defexception [:message]
    end

    @doc """
    Conditionally applies tenant filtering to a query.

    When `tenant_id` is nil:
    - `include_global: true` (default) — no tenant filter is applied
    - `include_global: false` — only global records (`tenant_id IS NULL`)

    When `tenant_id` is set, delegates to `apply_tenant/3`.
    """
    def maybe_apply_tenant(query, tenant_id, opts \\ []) do
      include_global = Keyword.get(opts, :include_global, true)

      cond do
        is_nil(tenant_id) and include_global ->
          query

        is_nil(tenant_id) ->
          do_apply_tenant(query, nil)

        true ->
          apply_tenant(query, tenant_id, opts)
      end
    end

    @doc """
    Applies tenant override logic to the given Ecto query.
    """
    def apply_tenant(query, tenant_id, opts \\ [])

    def apply_tenant(query, tenant_id, opts) do
      include_global = Keyword.get(opts, :include_global, true)
      key = Keyword.get(opts, :key, [])

      if include_global and not is_nil(tenant_id) do
        do_apply_tenant(query, tenant_id, key)
      else
        do_apply_tenant(query, tenant_id)
      end
    end

    def apply_tenant!(query, tenant_id, opts \\ [])

    def apply_tenant!(query, tenant_id, opts)
        when not is_nil(tenant_id) do
      apply_tenant(query, tenant_id, opts)
    end

    def apply_tenant!(_, _, _), do: raise(MissingTenantError, message: "Tenant is required")

    defp do_apply_tenant(query, tenant_id) do
      Dobro.Query.where_eq(query, :tenant_id, tenant_id)
    end

    # @todo: handle composite keys
    defp do_apply_tenant(query, tenant_id, key) do
      key_field =
        case key do
          [] -> :id
          [single_key] -> single_key
          _ -> raise ArgumentError, "Key must be a single field atom or an empty list"
        end

      tenant_key_query =
        from t in query,
          where: t.tenant_id == ^tenant_id,
          select: field(t, ^key_field)

      from t in query,
        where:
          t.tenant_id == ^tenant_id or
            (is_nil(t.tenant_id) and field(t, ^key_field) not in subquery(tenant_key_query))
    end
  end

  defmodule Params do
    @moduledoc """
    Helper module for normalizing query params
    """

    @doc """
    Normalizes the given query params into a list-query-compatible map
    """
    def normalize_query(params) when is_map(params) do
      params
      |> normalize_order()
      |> normalize_filters()
    end

    def normalize_query(nil), do: %{}

    def normalize_query(params) do
      raise "Invalid query params: #{inspect(params)}"
    end

    @doc """
    Converts a params map with `order: [%{field, direction}]` into
    `order` and `order_directions` lists.
    """
    def normalize_order(%{order: order_list} = params) when is_list(order_list) do
      {fields, directions} =
        Enum.reduce(order_list, {[], []}, fn
          %{"field" => field, "direction" => direction}, {fields_acc, dirs_acc} ->
            {[normalize_field(field) | fields_acc], [parse_direction(direction) | dirs_acc]}

          %{field: field, direction: direction}, {fields_acc, dirs_acc} ->
            {[normalize_field(field) | fields_acc], [parse_direction(direction) | dirs_acc]}

          _, acc ->
            acc
        end)

      params
      |> Map.delete(:order)
      |> Map.put(:order_by, Enum.reverse(fields))
      |> Map.put(:order_directions, Enum.reverse(directions))
    end

    def normalize_order(params), do: params

    def normalize_filters(%{filters: filters} = params) when is_list(filters) do
      Map.put(params, :filters, Enum.map(filters, &normalize_filter/1))
    end

    def normalize_filters(params), do: params

    defp normalize_filter(%{"field" => field} = filter) do
      Map.put(filter, "field", normalize_field_name(field))
    end

    defp normalize_filter(%{field: field} = filter) do
      Map.put(filter, :field, normalize_field_name(field))
    end

    defp normalize_filter(filter), do: filter

    defp normalize_field(field) when is_atom(field), do: field
    defp normalize_field(field) when is_binary(field), do: normalize_field_name(field)

    defp normalize_field_name(field) when is_atom(field),
      do: field |> Atom.to_string() |> normalize_field_name()

    defp normalize_field_name(field) when is_binary(field), do: Macro.underscore(field)

    defp parse_direction("ASC"), do: :asc
    defp parse_direction("DESC"), do: :desc
    defp parse_direction("asc"), do: :asc
    defp parse_direction("desc"), do: :desc
    defp parse_direction(:asc), do: :asc
    defp parse_direction(:desc), do: :desc
    defp parse_direction(_), do: :asc
  end
end
