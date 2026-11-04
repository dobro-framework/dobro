defmodule Dobro.Infra.Data.Query.Helpers do
  @moduledoc """
  Selection-aware query building primitives for read repositories.

  Low-level functions accept explicit config maps. Spec-aware wrappers delegate
  to primitives using fields from `%Dobro.Infra.Data.Query.Spec{}`.
  """

  import Ecto.Query

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.ExecutionContext
  alias Dobro.App.Selection
  alias Dobro.Infra.Data.Query.Spec
  alias Dobro.Infra.Data.ReadRepo.Context, as: RepoContext
  alias Dobro.Infra.SchemaPrefix

  @doc "Returns the selection from a read-repo or execution context, or nil."
  @spec selection(RepoContext.t() | ExecutionContext.t() | nil) :: Selection.t() | nil
  def selection(%RepoContext{selection: selection}), do: selection
  def selection(%ExecutionContext{selection: selection}), do: selection
  def selection(_), do: nil

  @doc """
  Resolves a join/preload `prefix` option to a Postgres schema name.

  - `nil` / omitted — no per-source prefix
  - `:tenant` — resolve via `SchemaPrefix` from the tenant on `context`
  - binary — use as-is
  """
  @spec resolve_prefix(term(), RepoContext.t() | ExecutionContext.t() | map() | nil) ::
          String.t() | nil
  def resolve_prefix(nil, _context), do: nil
  def resolve_prefix(prefix, _context) when is_binary(prefix), do: prefix

  def resolve_prefix(:tenant, context) do
    case tenant_from_context(context) do
      %TenantContext{} = tenant -> SchemaPrefix.schema_prefix_for!(tenant)
      _ -> raise ArgumentError, "prefix: :tenant requires a tenant on the read context"
    end
  end

  def resolve_prefix(other, _context) do
    raise ArgumentError, "unsupported join/preload prefix: #{inspect(other)}"
  end

  @doc "Repo options for a resolved prefix string (or empty list)."
  @spec prefix_repo_opts(String.t() | nil) :: keyword()
  def prefix_repo_opts(nil), do: []
  def prefix_repo_opts(prefix) when is_binary(prefix), do: [prefix: prefix]

  @doc "Computes fields needed for joins and projection from selection and query params."
  @spec needed_fields(Spec.t(), Selection.t() | nil, map() | nil) :: [atom()]
  def needed_fields(spec, selection, params) do
    query_fields = filter_fields(params) ++ sort_fields(params)

    # When GraphQL selects computed fields not on the query spec (e.g. `:status`),
    # load every declared field — same idea as One skipping projection.
    result_fields =
      if selection_covered_by_spec?(selection, spec) do
        selection_fields(selection, spec)
      else
        Map.keys(spec.fields)
      end

    (result_fields ++ query_fields)
    |> Enum.uniq()
    |> Enum.map(&normalize_field_name/1)
    |> Enum.filter(&Map.has_key?(spec.fields, &1))
    |> ensure_fields(spec, [:id])
  end

  @doc """
  Returns true when every selected scalar field is defined on the query spec.

  GraphQL result contracts often include computed fields (e.g. `:content`) that are
  not loaded from the database. Callers should skip SQL projection in that case.
  """
  @spec selection_covered_by_spec?(Selection.t() | nil, Spec.t()) :: boolean()
  def selection_covered_by_spec?(nil, _spec), do: true

  def selection_covered_by_spec?(%Selection{fields: fields}, %Spec{} = spec) do
    fields
    |> MapSet.to_list()
    |> Enum.map(&normalize_field_name/1)
    |> Enum.all?(&Map.has_key?(spec.fields, &1))
  end

  @doc "Applies only the joins required for `needed_fields`."
  @spec apply_joins(Ecto.Queryable.t(), Spec.t(), [atom()], term()) :: Ecto.Queryable.t()
  def apply_joins(queryable, %Spec{} = spec, needed_fields, context \\ nil) do
    spec
    |> Spec.joins_for_fields(needed_fields)
    |> Enum.reduce(queryable, fn join_spec, query ->
      apply_join(query, join_spec.name, join_spec, context)
    end)
  end

  @doc "Spec-aware wrapper — applies joins required by selection and query params."
  def apply_spec_joins(queryable, %Spec{} = spec, selection, params, context \\ nil) do
    needed = needed_fields(spec, selection, params)
    apply_joins(queryable, spec, needed, context)
  end

  @doc "Spec-aware wrapper — projects fields required by selection and query params."
  def apply_spec_select(queryable, %Spec{} = spec, selection, params) do
    needed = needed_fields(spec, selection, params)
    apply_select(queryable, spec.fields, needed)
  end

  @doc "Projects `needed_fields` from the queryable."
  @spec apply_select(Ecto.Queryable.t(), map(), [atom()]) :: Ecto.Queryable.t()
  def apply_select(%Ecto.Query{select: %{expr: _}} = queryable, _fields, _needed_fields), do: queryable

  def apply_select(queryable, fields, needed_fields) do
    select_map =
      needed_fields
      |> Enum.filter(&Map.has_key?(fields, &1))
      |> Map.new(fn field ->
        {field, select_expr(Map.fetch!(fields, field))}
      end)

    from q in queryable, select: ^select_map
  end

  @doc "Spec-aware wrapper — applies conditional preloads from a query spec."
  def apply_spec_preloads(queryable, %Spec{} = spec, context) do
    apply_preloads(queryable, spec.preloads, selection(context), context)
  end

  @doc "Applies conditional association preloads based on `selection`."
  @spec apply_preloads(Ecto.Queryable.t(), [map()], Selection.t() | nil, term()) ::
          Ecto.Queryable.t()
  def apply_preloads(queryable, preloads, selection, context \\ nil) do
    Enum.reduce(preloads, queryable, fn preload_spec, query ->
      if preload_selected?(preload_spec.name, selection) do
        assoc = preload_spec.name
        preload_query = preload_query(preload_spec, selection, context)
        preload(query, [{^assoc, ^preload_query}])
      else
        query
      end
    end)
  end

  @doc false
  def apply_join(query, join_name, join_spec, context \\ nil)

  def apply_join(query, join_name, %{schema: schema, type: type, on: on} = join_spec, context)
      when type in [:left, :inner] do
    {left_binding, left_field, _right_binding, right_field} = on
    prefix = resolve_prefix(Map.get(join_spec, :prefix), context)
    deleted_field = Map.get(join_spec, :and_not_deleted)

    do_apply_join(query, type, left_binding, left_field, right_field, schema, join_name, prefix, deleted_field)
  end

  def apply_join(query, join_name, %{type: type} = join_spec, context)
      when type not in [:left, :inner] do
    apply_join(query, join_name, Map.put(join_spec, :type, :inner), context)
  end

  defp do_apply_join(query, type, left_binding, {:expr, left_expr}, right_field, schema, join_name, prefix, nil) do
    # `^dynamic` must be the entire `on:` value. Bind the join by its `as:` name so
    # the right-hand side is not confused with the parent binding.
    left = Spec.resolve_expr(left_expr)
    on_expr = dynamic([{^join_name, assoc}], ^left == field(assoc, ^right_field))

    apply_expr_join(query, type, left_binding, schema, join_name, prefix, on_expr)
  end

  defp do_apply_join(
         query,
         type,
         left_binding,
         {:expr, left_expr},
         right_field,
         schema,
         join_name,
         prefix,
         deleted_field
       )
       when is_atom(deleted_field) do
    left = Spec.resolve_expr(left_expr)

    on_expr =
      dynamic(
        [{^join_name, assoc}],
        ^left == field(assoc, ^right_field) and
          (field(assoc, ^deleted_field) != true or is_nil(field(assoc, ^deleted_field)))
      )

    apply_expr_join(query, type, left_binding, schema, join_name, prefix, on_expr)
  end

  defp do_apply_join(query, type, left_binding, left_field, right_field, schema, join_name, prefix, nil)
       when is_atom(left_field) do
    if prefix do
      join(query, type, [{^left_binding, left}], assoc in ^schema,
        on: field(left, ^left_field) == field(assoc, ^right_field),
        as: ^join_name,
        prefix: ^prefix
      )
    else
      join(query, type, [{^left_binding, left}], assoc in ^schema,
        on: field(left, ^left_field) == field(assoc, ^right_field),
        as: ^join_name
      )
    end
  end

  defp do_apply_join(query, type, left_binding, left_field, right_field, schema, join_name, prefix, deleted_field)
       when is_atom(left_field) and is_atom(deleted_field) do
    if prefix do
      join(query, type, [{^left_binding, left}], assoc in ^schema,
        on:
          field(left, ^left_field) == field(assoc, ^right_field) and
            (field(assoc, ^deleted_field) != true or is_nil(field(assoc, ^deleted_field))),
        as: ^join_name,
        prefix: ^prefix
      )
    else
      join(query, type, [{^left_binding, left}], assoc in ^schema,
        on:
          field(left, ^left_field) == field(assoc, ^right_field) and
            (field(assoc, ^deleted_field) != true or is_nil(field(assoc, ^deleted_field))),
        as: ^join_name
      )
    end
  end

  defp apply_expr_join(query, type, left_binding, schema, join_name, prefix, on_expr) do
    # `as:` before `on:` so the join name is available to the on dynamic.
    if prefix do
      join(query, type, [{^left_binding, _left}], assoc in ^schema,
        as: ^join_name,
        on: ^on_expr,
        prefix: ^prefix
      )
    else
      join(query, type, [{^left_binding, _left}], assoc in ^schema,
        as: ^join_name,
        on: ^on_expr
      )
    end
  end

  defp select_expr({:column, binding, source}) do
    dynamic([{^binding, row}], field(row, ^source))
  end

  defp select_expr({:join, join, source}) do
    dynamic([{^join, row}], field(row, ^source))
  end

  defp select_expr({:join_expr, _join, expr}), do: Spec.resolve_expr(expr)

  defp select_expr({:expr, expr}), do: Spec.resolve_expr(expr)

  @doc "Builds the Ecto query for a conditional association preload."
  @spec assoc_preload_query(map(), Selection.t() | nil, term()) :: Ecto.Query.t()
  def assoc_preload_query(preload_spec, selection, context \\ nil),
    do: preload_query(preload_spec, selection, context)

  @doc "Returns whether an association preload is included in `selection`."
  @spec preload_selected?(atom(), Selection.t() | nil) :: boolean()
  def preload_selected?(_name, nil), do: true

  def preload_selected?(name, %Selection{associations: associations}) do
    Map.has_key?(associations, name)
  end

  @doc """
  Like `preload_selected?/2`, but also treats domain fields that map from the
  association (via `Dobro.Infra.Data.Mappings`) as selecting that association.
  """
  @spec preload_selected?(atom(), Selection.t() | nil, Dobro.Infra.Data.Mappings.t()) :: boolean()
  def preload_selected?(name, selection, mappings) do
    preload_selected?(name, selection) or
      Dobro.Infra.Data.Mappings.association_selected?(name, selection, mappings)
  end

  defp preload_query(preload_spec, selection, context) do
    preload_spec
    |> Map.put_new(:preloads, [])
    |> base_preload_query(selection, context)
    |> apply_nested_preloads(preload_spec, selection, context)
  end

  defp base_preload_query(%{schema: schema, fields: nil} = spec, _selection, context) do
    case resolve_prefix(Map.get(spec, :prefix), context) do
      nil -> from(s in schema)
      prefix -> from(s in schema, prefix: ^prefix)
    end
  end

  defp base_preload_query(
         %{name: name, schema: schema, fields: default_fields} = spec,
         %Selection{} = selection,
         context
       ) do
    prefix = resolve_prefix(Map.get(spec, :prefix), context)
    fields =
      case Map.get(selection.associations, name) do
        %Selection{fields: assoc_fields} when map_size(assoc_fields) > 0 ->
          MapSet.to_list(assoc_fields)

        _ ->
          default_fields
      end

    prefixed_from(schema, fields, prefix)
  end

  defp base_preload_query(%{schema: schema, fields: fields} = spec, _selection, context) do
    prefix = resolve_prefix(Map.get(spec, :prefix), context)
    prefixed_from(schema, fields, prefix)
  end

  defp prefixed_from(schema, nil, nil), do: from(s in schema)
  defp prefixed_from(schema, nil, prefix), do: from(s in schema, prefix: ^prefix)
  defp prefixed_from(schema, fields, nil), do: from(s in schema, select: ^fields)
  defp prefixed_from(schema, fields, prefix), do: from(s in schema, prefix: ^prefix, select: ^fields)

  defp apply_nested_preloads(query, %{preloads: []}, _selection, _context), do: query

  defp apply_nested_preloads(query, %{preloads: nested, name: name} = _spec, selection, context) do
    parent_selection = nested_parent_selection(selection, name)

    nested_pairs =
      Enum.map(nested, fn nested_spec ->
        {nested_spec.name,
         preload_query(nested_spec, nested_parent_selection(parent_selection, nested_spec.name), context)}
      end)

    preload(query, ^nested_pairs)
  end

  defp nested_parent_selection(nil, _name), do: nil

  defp nested_parent_selection(%Selection{associations: associations}, name) do
    Map.get(associations, name)
  end

  defp tenant_from_context(%RepoContext{tenant: tenant}), do: tenant
  defp tenant_from_context(%ExecutionContext{tenant: tenant}), do: tenant
  defp tenant_from_context(%{tenant: tenant}), do: tenant
  defp tenant_from_context(_), do: nil

  defp selection_fields(nil, spec), do: Map.keys(spec.fields)

  defp selection_fields(%Selection{fields: fields, associations: associations}, spec) do
    scalar_fields =
      if MapSet.size(fields) > 0, do: MapSet.to_list(fields), else: Map.keys(spec.fields)

    # Nested contract fields (e.g. `Contracts.Address`) are tracked as associations in
    # GraphQL selection, but may still be loaded via `field/1` exprs on the query spec.
    embedded_fields =
      associations
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(spec.fields, &1))

    Enum.uniq(scalar_fields ++ embedded_fields)
  end

  defp filter_fields(%{filters: filters}) when is_list(filters) do
    Enum.map(filters, fn filter -> normalize_field_name(field_name(filter)) end)
  end

  defp filter_fields(_), do: []

  defp sort_fields(%{order_by: order_by}) when is_list(order_by), do: order_by
  defp sort_fields(_), do: []

  defp ensure_fields(fields, spec, required) do
    Enum.uniq(fields ++ Enum.filter(required, &Map.has_key?(spec.fields, &1)))
  end

  defp field_name(%{field: field}), do: field
  defp field_name(%{"field" => field}), do: field

  defp normalize_field_name(field) when is_atom(field), do: field

  defp normalize_field_name(field) when is_binary(field) do
    field
    |> Macro.underscore()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> String.to_atom(field)
  end
end
