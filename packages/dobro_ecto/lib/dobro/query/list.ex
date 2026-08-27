defmodule Dobro.Query.List do
  @moduledoc """
  Validates and runs paginated, filterable list queries against Ecto queryables.
  """

  import Ecto.Query

  alias Dobro.Error
  alias Dobro.Infra.Data.Query.{Helpers, Spec}
  alias Dobro.Query.List.Filter
  alias Dobro.Query.Params

  @type meta :: %{
          current_page: pos_integer(),
          page_size: pos_integer(),
          total_count: non_neg_integer(),
          total_pages: non_neg_integer()
        }

  @doc """
  Runs a list query described by `spec` against `queryable` with `params`.
  """
  @spec run(Ecto.Queryable.t(), map() | nil, Spec.t(), keyword()) ::
          {:ok, %{items: list(), meta: meta()}} | {:error, term()}
  def run(queryable, params, %Spec{} = spec, opts \\ []) do
    params = Params.normalize_query(params)
    selection = Keyword.get(opts, :selection)

    with :ok <- validate_params(params, spec),
         {:ok, params} <- cast_filter_values(params, spec) do
      page_fields = Helpers.needed_fields(spec, selection, params)
      # COUNT only needs joins required by filters — not display joins (e.g. names).
      count_fields =
        params
        |> filter_fields()
        |> Enum.map(&normalize_field_name/1)
        |> Enum.filter(&Map.has_key?(spec.fields, &1))

      base = base_query(queryable, spec)

      count_queryable =
        base
        |> maybe_apply_joins(spec, count_fields)
        |> apply_filters(spec, params)

      page_queryable =
        base
        |> maybe_apply_joins(spec, page_fields)
        |> maybe_apply_select(spec, page_fields)
        |> apply_filters(spec, params)
        |> apply_order(spec, params)

      paginate(page_queryable, count_queryable, params, spec, opts)
    end
  end

  defp base_query(queryable, %Spec{schema: schema, root_binding: binding}) do
    case queryable do
      %Ecto.Query{} -> queryable
      _ -> from(s in schema, as: ^binding)
    end
  end

  defp filter_fields(%{filters: filters}) when is_list(filters) do
    Enum.map(filters, fn filter -> normalize_field_name(field_name(filter)) end)
  end

  defp filter_fields(_), do: []

  defp validate_params(params, spec) do
    errors =
      []
      |> validate_filter_fields(params, spec)
      |> validate_sort_fields(params, spec)

    case errors do
      [] -> :ok
      {:error, _} = error -> error
      errors -> {:error, Error.new(:query_validation_error, description: Enum.join(errors, ", "))}
    end
  end

  defp validate_filter_fields(errors, %{filters: filters}, spec) when is_list(filters) do
    Enum.reduce(filters, errors, fn filter, acc ->
      field = field_name(filter) |> normalize_field_name()

      acc =
        if MapSet.member?(spec.filterable, field),
          do: acc,
          else: ["invalid filter field: #{field}" | acc]

      case filter_op(filter) do
        {:error, :invalid_op} ->
          op = Map.get(filter, :op) || Map.get(filter, "op")
          ["invalid filter op: #{inspect(op)}" | acc]

        {:ok, _} ->
          acc
      end
    end)
  end

  defp validate_filter_fields(errors, _, _), do: errors

  defp validate_sort_fields(errors, %{order_by: order_by}, spec) when is_list(order_by) do
    Enum.reduce(order_by, errors, fn field, acc ->
      field = normalize_field_name(field)

      if MapSet.member?(spec.sortable, field),
        do: acc,
        else: ["invalid sort field: #{field}" | acc]
    end)
  end

  defp validate_sort_fields(errors, _, _), do: errors

  defp cast_filter_values(%{filters: filters} = params, spec) when is_list(filters) do
    casted = Enum.map(filters, &cast_filter_value(&1, spec))
    {:ok, %{params | filters: casted}}
  end

  defp cast_filter_values(params, _spec), do: {:ok, params}

  # Always succeeds: invalid ops/fields pass through; bad values become unmatchable.
  defp cast_filter_value(filter, spec) do
    field = field_name(filter) |> normalize_field_name()

    with {:ok, op} <- filter_op(filter),
         {:ok, source} <- Map.fetch(spec.fields, field),
         {:ok, value} <- Filter.cast_value(ecto_type(spec, source), op, filter_value(filter)) do
      put_filter_value(filter, value)
    else
      :error ->
        filter

      {:error, :invalid_op} ->
        filter

      {:error, :invalid_filter_value} ->
        # e.g. Equals "abc" on an :id column — match nothing rather than fail the query
        put_filter_value(filter, Filter.unmatchable())
    end
  end

  defp ecto_type(%Spec{schema: schema}, {:column, _binding, column}) do
    schema.__schema__(:type, column)
  end

  defp ecto_type(%Spec{joins: joins}, {:join, join_name, column}) do
    case Enum.find(joins, &(&1.name == join_name)) do
      %{schema: schema} -> schema.__schema__(:type, column)
      nil -> nil
    end
  end

  defp ecto_type(_spec, {:expr, _}), do: nil

  defp put_filter_value(%{} = filter, value) when is_map_key(filter, :value),
    do: %{filter | value: value}

  defp put_filter_value(%{} = filter, value) when is_map_key(filter, "value"),
    do: Map.put(filter, "value", value)

  defp put_filter_value(filter, value), do: Map.put(filter, :value, value)

  defp maybe_apply_joins(%Ecto.Query{select: %{expr: _}} = queryable, _spec, _fields), do: queryable
  defp maybe_apply_joins(queryable, spec, needed_fields), do: apply_joins(queryable, spec, needed_fields)

  defp maybe_apply_select(%Ecto.Query{select: %{expr: _}} = queryable, _spec, _fields), do: queryable
  defp maybe_apply_select(queryable, spec, needed_fields), do: apply_select(queryable, spec, needed_fields)

  defp apply_joins(queryable, spec, needed_fields) do
    spec
    |> Spec.joins_for_fields(needed_fields)
    |> Enum.reduce(queryable, fn join_spec, query ->
      apply_join(query, join_spec.name, join_spec)
    end)
  end

  defp apply_join(query, join_name, %{schema: schema, type: :left, on: on}) do
    {left_binding, left_field, _right_binding, right_field} = on

    join(query, :left, [{^left_binding, left}], assoc in ^schema,
      on: field(left, ^left_field) == field(assoc, ^right_field),
      as: ^join_name
    )
  end

  defp apply_join(query, join_name, %{schema: schema, type: :inner, on: on}) do
    {left_binding, left_field, _right_binding, right_field} = on

    join(query, :inner, [{^left_binding, left}], assoc in ^schema,
      on: field(left, ^left_field) == field(assoc, ^right_field),
      as: ^join_name
    )
  end

  defp apply_join(query, join_name, %{schema: schema, type: type, on: on})
       when type not in [:left, :inner] do
    apply_join(query, join_name, %{schema: schema, type: :inner, on: on})
  end

  defp apply_select(queryable, spec, needed_fields) do
    select_map =
      Map.new(needed_fields, fn field ->
        {field, select_expr(Map.fetch!(spec.fields, field), spec)}
      end)

    from q in queryable, select: ^select_map
  end

  defp select_expr({:column, binding, source}, _spec) do
    dynamic([{^binding, row}], field(row, ^source))
  end

  defp select_expr({:join, join, source}, _spec) do
    dynamic([{^join, row}], field(row, ^source))
  end

  defp select_expr({:expr, expr}, _spec), do: Spec.resolve_expr(expr)

  defp apply_filters(queryable, spec, %{filters: filters} = params) when is_list(filters) do
    case filter_logic(params) do
      :or -> apply_or_filters(queryable, spec, filters)
      :and -> Enum.reduce(filters, queryable, &apply_filter(&2, spec, &1))
    end
  end

  defp apply_filters(queryable, _, _), do: queryable

  defp filter_logic(params) do
    params
    |> Map.get(:filter_logic, Map.get(params, "filter_logic", "and"))
    |> normalize_filter_logic()
  end

  defp normalize_filter_logic(logic) when logic in [:or, :OR, "or", "OR", "Or"], do: :or
  defp normalize_filter_logic(logic) when logic in [:and, :AND, "and", "AND", "And"], do: :and
  defp normalize_filter_logic(_), do: :and

  defp apply_or_filters(queryable, spec, filters) do
    dynamics =
      filters
      |> Enum.map(&filter_dynamic(spec, &1))
      |> Enum.reject(&is_nil/1)

    case dynamics do
      [] ->
        queryable

      [only] ->
        where(queryable, ^only)

      [first | rest] ->
        combined = Enum.reduce(rest, first, fn dynamic, acc -> dynamic(^acc or ^dynamic) end)
        where(queryable, ^combined)
    end
  end

  defp filter_dynamic(spec, filter) do
    field = field_name(filter) |> normalize_field_name()

    with {:ok, op} <- filter_op(filter),
         {:ok, source} <- Map.fetch(spec.fields, field) do
      Filter.dynamic_condition(source, op, filter_value(filter))
    else
      _ -> nil
    end
  end

  defp apply_filter(queryable, spec, filter) do
    field = field_name(filter) |> normalize_field_name()

    with {:ok, op} <- filter_op(filter),
         {:ok, source} <- Map.fetch(spec.fields, field) do
      Filter.apply(queryable, source, op, filter_value(filter))
    else
      _ -> queryable
    end
  end

  defp apply_order(queryable, spec, %{order_by: order_by, order_directions: directions})
       when is_list(order_by) and order_by != [] and is_list(directions) do
    orders =
      Enum.zip(order_by, directions)
      |> Enum.map(fn {field, direction} ->
        {parse_direction(direction), order_expr(spec, normalize_field_name(field))}
      end)

    order_by(queryable, ^orders)
  end

  defp apply_order(queryable, spec, %{order_by: order_by})
       when is_list(order_by) and order_by != [] do
    orders = Enum.map(order_by, fn field -> {:asc, order_expr(spec, normalize_field_name(field))} end)
    order_by(queryable, ^orders)
  end

  defp apply_order(queryable, %Spec{default_order: default_order} = spec, _params)
       when is_list(default_order) and default_order != [] do
    orders =
      Enum.map(default_order, fn {direction, field} ->
        {direction, order_expr(spec, field)}
      end)

    order_by(queryable, ^orders)
  end

  defp apply_order(queryable, _, _), do: queryable

  defp order_expr(spec, field) do
    case Map.fetch!(spec.fields, field) do
      {:column, binding, source} -> dynamic([{^binding, row}], field(row, ^source))
      {:join, join, source} -> dynamic([{^join, row}], field(row, ^source))
      {:expr, expr} -> Spec.resolve_expr(expr)
    end
  end

  defp paginate(page_queryable, count_queryable, params, spec, opts) do
    page = param(params, :page, 1)
    page_size = param(params, :page_size, param(params, :limit, spec.default_limit))
    offset = (page - 1) * page_size
    repo = Keyword.get(opts, :repo)
    strategy_opts = Keyword.get(opts, :strategy_opts, [])

    with {:ok, total_count} <-
           resolve_total_count(count_queryable, spec, opts, repo, strategy_opts),
         {:ok, items} <- fetch_items(repo, page_queryable, page_size, offset, strategy_opts) do
      total_pages = if page_size > 0, do: div(total_count + page_size - 1, page_size), else: 0

      {:ok,
       %{
         items: items,
         meta: %{
           current_page: page,
           page_size: page_size,
           total_count: total_count,
           total_pages: total_pages
         }
       }}
    end
  end

  defp resolve_total_count(count_queryable, spec, opts, repo, strategy_opts) do
    cond do
      match?(n when is_integer(n) and n >= 0, Keyword.get(opts, :total_count)) ->
        {:ok, Keyword.get(opts, :total_count)}

      spec.count == :skip ->
        {:ok, 0}

      spec.count == :estimated ->
        estimated_count(repo, count_queryable, strategy_opts)

      true ->
        aggregate_count(repo, count_queryable, strategy_opts)
    end
  end

  defp estimated_count(repo, queryable, strategy_opts) do
    explain_opts =
      strategy_opts
      |> Keyword.put(:analyze, false)
      |> Keyword.put(:format, :map)

    count_query =
      queryable
      |> exclude(:select)
      |> exclude(:order_by)
      |> exclude(:limit)
      |> exclude(:offset)
      |> select([_], 1)

    plans =
      case repo do
        nil -> Dobro.Infra.Repo.explain(:all, count_query, explain_opts)
        mod -> explain_via(mod, count_query, explain_opts)
      end

    {:ok, plan_rows(plans)}
  rescue
    _ -> aggregate_count(repo, queryable, strategy_opts)
  end

  defp explain_via(repo_module, queryable, opts) do
    if function_exported?(repo_module, :explain, 3) do
      repo_module.explain(:all, queryable, opts)
    else
      Dobro.Infra.Repo.explain(:all, queryable, opts)
    end
  end

  defp plan_rows([%{"Plan" => plan} | _]) when is_map(plan) do
    plan
    |> get_in(["Plan Rows"])
    |> case do
      rows when is_integer(rows) and rows >= 0 -> rows
      _ -> 0
    end
  end

  defp plan_rows(_), do: 0

  defp aggregate_count(nil, queryable, _strategy_opts) do
    {:ok, Dobro.Infra.Repo.aggregate(queryable, :count)}
  end

  defp aggregate_count(repo, queryable, strategy_opts) do
    case repo.aggregate(queryable, :count, strategy_opts) do
      count when is_integer(count) -> {:ok, count}
      {:error, _} = error -> error
    end
  end

  defp fetch_items(nil, queryable, page_size, offset, _strategy_opts) do
    items =
      queryable
      |> limit(^page_size)
      |> offset(^offset)
      |> Dobro.Infra.Repo.all()

    {:ok, items}
  end

  defp fetch_items(repo, queryable, page_size, offset, strategy_opts) do
    case repo.all(
           queryable
           |> limit(^page_size)
           |> offset(^offset),
           strategy_opts
         ) do
      items when is_list(items) -> {:ok, items}
      {:error, _} = error -> error
    end
  end

  defp param(params, key, default) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key)) || default
  end

  defp field_name(%{field: field}), do: field
  defp field_name(%{"field" => field}), do: field

  defp filter_op(%{op: op}), do: Filter.parse_op(op)
  defp filter_op(%{"op" => op}), do: Filter.parse_op(op)
  defp filter_op(_), do: {:error, :invalid_op}

  defp filter_value(%{value: value}), do: value
  defp filter_value(%{"value" => value}), do: value

  defp parse_direction(dir) when dir in [:asc, :desc, "asc", "desc", "ASC", "DESC"] do
    dir |> to_string() |> String.downcase() |> String.to_existing_atom()
  end

  defp parse_direction(_), do: :asc

  defp normalize_field_name(field) when is_atom(field), do: field

  defp normalize_field_name(field) when is_binary(field) do
    field
    |> Macro.underscore()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> String.to_atom(field)
  end
end
