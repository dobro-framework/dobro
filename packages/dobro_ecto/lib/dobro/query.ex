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
      from(q in queryable, where: is_nil(field(q, ^field)))
    else
      from(q in queryable, where: field(q, ^field) == ^value)
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

    `owner:` (a list of `:tenant` / `:global`) keeps the rows the request asks
    for, relative to the request: inside a tenant, `:tenant` is that tenant's
    rows; working globally, every tenant's. Without it,
    `%Dobro.App.Auth.GlobalContext{}` applies no filter, and a
    `%Dobro.App.Auth.TenantContext{}` or integer id delegates to `apply_tenant/3`
    (`include_global`: `true` adds rows whose `tenant_id` is null). Nil raises
    `MissingTenantError`.
    """
    def maybe_apply_tenant(query, tenant, opts \\ [])

    def maybe_apply_tenant(query, %Dobro.App.Auth.GlobalContext{}, opts) do
      case Keyword.get(opts, :owner) do
        nil -> query
        owner -> global_owner(query, normalize_owner(owner))
      end
    end

    def maybe_apply_tenant(query, %Dobro.App.Auth.TenantContext{id: id}, opts)
        when not is_nil(id) do
      apply_tenant(query, id, opts)
    end

    def maybe_apply_tenant(query, tenant_id, opts) when is_integer(tenant_id) do
      apply_tenant(query, tenant_id, opts)
    end

    def maybe_apply_tenant(_query, _tenant, _opts) do
      raise MissingTenantError, message: "Tenant is required"
    end

    @doc """
    Applies tenant override logic to the given Ecto query.
    """
    def apply_tenant(query, tenant_id, opts \\ [])

    def apply_tenant(query, tenant_id, opts) do
      key = Keyword.get(opts, :key, [])

      case Keyword.get(opts, :owner) do
        nil ->
          if Keyword.get(opts, :include_global, true) and not is_nil(tenant_id),
            do: do_apply_tenant(query, tenant_id, key),
            else: do_apply_tenant(query, tenant_id)

        owner ->
          case normalize_owner(owner) do
            [:tenant, :global] -> do_apply_tenant(query, tenant_id, key)
            [:tenant] -> do_apply_tenant(query, tenant_id)
            [:global] -> where_global(query)
            [] -> where_none(query)
          end
      end
    end

    def apply_tenant!(query, tenant_id, opts \\ [])

    def apply_tenant!(query, tenant_id, opts)
        when not is_nil(tenant_id) do
      apply_tenant(query, tenant_id, opts)
    end

    def apply_tenant!(_, _, _), do: raise(MissingTenantError, message: "Tenant is required")

    @doc """
    Normalises a requested owner list (atoms, or strings from an API) to a
    sorted subset of `[:tenant, :global]`. Nil or empty is nil: the default.
    """
    def normalize_owner(nil), do: nil
    def normalize_owner([]), do: nil

    def normalize_owner(owner) when is_list(owner) do
      wanted = Enum.map(owner, &owner_atom/1)
      Enum.filter([:tenant, :global], &(&1 in wanted))
    end

    defp owner_atom(value) when value in [:tenant, :global], do: value

    defp owner_atom(value) when is_binary(value) do
      case String.downcase(value) do
        "tenant" -> :tenant
        "global" -> :global
        _ -> nil
      end
    end

    defp owner_atom(_value), do: nil

    # Working globally: `:tenant` is every tenant's rows.
    defp global_owner(query, [:tenant, :global]), do: query
    defp global_owner(query, [:global]), do: where_global(query)

    defp global_owner(query, [:tenant]) do
      import Ecto.Query, only: [where: 3]
      where(query, [row], not is_nil(field(row, :tenant_id)))
    end

    defp global_owner(query, _none), do: where_none(query)

    defp where_global(query) do
      import Ecto.Query, only: [where: 3]
      where(query, [row], is_nil(field(row, :tenant_id)))
    end

    defp where_none(query) do
      import Ecto.Query, only: [where: 2]
      where(query, false)
    end

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
        from(t in Ecto.Query.exclude(query, [:select, :order_by, :limit, :offset, :preload]),
          where: t.tenant_id == ^tenant_id,
          select: field(t, ^key_field)
        )

      from(t in query,
        where:
          t.tenant_id == ^tenant_id or
            (is_nil(t.tenant_id) and field(t, ^key_field) not in subquery(tenant_key_query))
      )
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
