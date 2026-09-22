defmodule Dobro.Query.Facet do
  @moduledoc """
  Runs distinct-value (facet) queries against Ecto queryables.

  Given a compiled `:facet` query spec and `args.field`, returns sorted unique
  non-nil string values for that column. Optional `args.query` filters use the
  same Flop-compatible ops as list queries.
  """

  import Ecto.Query

  alias Dobro.Error
  alias Dobro.Infra.Data.Query.Spec
  alias Dobro.Query.List.Filter
  alias Dobro.Query.Params

  @doc """
  Runs a facet query described by `spec` against `queryable` with `args`.

  Expects `args.field` (atom or string) naming a column in `spec.facets`.
  Optional `args.query` may include filters against `spec.filterable` fields.
  """
  @spec run(Ecto.Queryable.t(), map(), Spec.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def run(queryable, args, %Spec{} = spec, opts \\ []) when is_map(args) do
    params = args |> Map.get(:query) |> Params.normalize_query()
    repo = Keyword.get(opts, :repo)
    strategy_opts = Keyword.get(opts, :strategy_opts, [])

    with {:ok, field} <- resolve_field(args, spec),
         :ok <- validate_filters(params, spec),
         {:ok, params} <- cast_filter_values(params, spec) do
      source = Map.fetch!(spec.fields, field)

      queryable
      |> base_query(spec)
      |> apply_filters(spec, params)
      |> apply_facet(source)
      |> fetch_values(repo, strategy_opts)
      |> then(fn
        {:ok, values} -> {:ok, Enum.map(values, &stringify/1)}
        error -> error
      end)
    end
  end

  defp resolve_field(args, %Spec{facets: facets}) do
    raw = Map.get(args, :field) || Map.get(args, "field")

    cond do
      is_nil(raw) or raw == "" ->
        {:error, Error.new(:query_validation_error, description: "field is required")}

      true ->
        field = normalize_field_name(raw)

        if MapSet.member?(facets, field) do
          {:ok, field}
        else
          {:error,
           Error.new(:query_validation_error,
             description: "invalid facet field: #{field}"
           )}
        end
    end
  end

  defp validate_filters(%{filters: filters}, spec) when is_list(filters) do
    errors =
      Enum.reduce(filters, [], fn filter, acc ->
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

    case errors do
      [] -> :ok
      errors -> {:error, Error.new(:query_validation_error, description: Enum.join(errors, ", "))}
    end
  end

  defp validate_filters(_, _), do: :ok

  defp cast_filter_values(%{filters: filters} = params, spec) when is_list(filters) do
    casted = Enum.map(filters, &cast_filter_value(&1, spec))
    {:ok, %{params | filters: casted}}
  end

  defp cast_filter_values(params, _spec), do: {:ok, params}

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

  defp base_query(queryable, %Spec{schema: schema, root_binding: binding}) do
    case queryable do
      %Ecto.Query{} -> queryable
      _ -> from(s in schema, as: ^binding)
    end
  end

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

  defp apply_facet(queryable, source) do
    expr = field_expr(source)

    queryable
    |> where(^dynamic(not is_nil(^expr)))
    |> distinct(true)
    |> order_by(^[{:asc, expr}])
    |> select(^expr)
  end

  defp field_expr({:column, binding, column}) do
    dynamic([{^binding, row}], field(row, ^column))
  end

  defp field_expr({:join, join, column}) do
    dynamic([{^join, row}], field(row, ^column))
  end

  defp field_expr({:expr, expr}), do: Spec.resolve_expr(expr)

  defp fetch_values(queryable, nil, _strategy_opts) do
    {:ok, Dobro.Infra.Repo.all(queryable)}
  end

  defp fetch_values(queryable, repo, strategy_opts) do
    case repo.all(queryable, strategy_opts) do
      values when is_list(values) -> {:ok, values}
      {:error, _} = error -> error
    end
  end

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp field_name(%{field: field}), do: field
  defp field_name(%{"field" => field}), do: field

  defp filter_op(%{op: op}), do: Filter.parse_op(op)
  defp filter_op(%{"op" => op}), do: Filter.parse_op(op)
  defp filter_op(_), do: {:error, :invalid_op}

  defp filter_value(%{value: value}), do: value
  defp filter_value(%{"value" => value}), do: value

  defp normalize_field_name(field) when is_atom(field), do: field

  defp normalize_field_name(field) when is_binary(field) do
    field
    |> Macro.underscore()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> String.to_atom(field)
  end
end
