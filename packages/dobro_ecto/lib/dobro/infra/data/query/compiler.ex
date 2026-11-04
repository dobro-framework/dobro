defmodule Dobro.Infra.Data.Query.Compiler do
  @moduledoc false

  alias Dobro.Infra.Data.Query.{Join, Spec}

  def compile(type, name, opts, block, env) do
    repo = env.module
    schema = schema(opts, env)
    root_binding = Keyword.get(opts, :binding, Spec.infer_root_binding(schema))
    default_limit = Keyword.get(opts, :default_limit, 10)
    id_field = Keyword.get(opts, :id_field, :id)
    query_fn = query_function_name(name)
    ctx = %{repo: repo, query_name: name}

    case type do
      :list -> compile_list(repo, schema, root_binding, default_limit, query_fn, block, env, ctx, opts)
      :one -> compile_one(repo, schema, id_field, root_binding, query_fn, block, env, ctx, opts)
      :exists -> compile_exists(repo, schema, id_field, query_fn, block, env, ctx, opts)
      :facet -> compile_facet(repo, schema, root_binding, query_fn, block, env, ctx, opts)
    end
  end

  defp compile_list(repo, schema, root_binding, default_limit, query_fn, block, env, ctx, opts) do
    {joins, fields, config, query_ast, expr_defs} = compile_block(block, schema, root_binding, env, ctx)
    fields = apply_exclude(fields, config)

    ensure_fields!(fields, :list)

    query =
      case query_ast do
        nil -> nil
        _ast -> {repo, query_fn, 2}
      end

    default_order =
      opts
      |> Keyword.get(:default_order, Keyword.get(config, :default_order, []))
      |> normalize_default_order!()

    count =
      opts
      |> Keyword.get(:count, Keyword.get(config, :count, :exact))
      |> normalize_count!()

    spec = %Spec{
      module: nil,
      repo: repo,
      type: :list,
      schema: schema,
      root_binding: root_binding,
      fields: fields,
      joins: joins,
      filterable: finalize_queryable(config, :filterable),
      sortable: finalize_queryable(config, :sortable),
      default_limit: default_limit,
      default_order: default_order,
      count: count,
      query: query,
      enriches: finalize_enriches(config),
      include_global: Keyword.get(opts, :include_global)
    }

    {spec, query_ast, expr_defs}
  end

  defp compile_one(repo, schema, id_field, root_binding, query_fn, block, env, ctx, opts) do
    {joins, fields, config, query_ast, expr_defs} = compile_block(block, schema, root_binding, env, ctx)
    fields = apply_exclude(fields, config)

    ensure_fields!(fields, :one)

    query =
      case query_ast do
        nil -> nil
        _ast -> {repo, query_fn, 2}
      end

    spec = %Spec{
      module: nil,
      repo: repo,
      type: :one,
      schema: schema,
      id_field: id_field,
      root_binding: root_binding,
      fields: fields,
      joins: joins,
      preloads: Keyword.get(config, :preloads, []),
      enriches: finalize_enriches(config),
      query: query,
      include_global: Keyword.get(opts, :include_global)
    }

    {spec, query_ast, expr_defs}
  end

  defp compile_exists(repo, schema, id_field, query_fn, block, env, ctx, opts) do
    root_binding = Spec.infer_root_binding(schema)
    {_, _, config, query_ast, expr_defs} = compile_block(block, schema, root_binding, env, ctx)

    query =
      case query_ast do
        nil -> nil
        _ast -> {repo, query_fn, 2}
      end

    spec = %Spec{
      module: nil,
      repo: repo,
      type: :exists,
      schema: schema,
      id_field: id_field,
      filterable: finalize_queryable(config, :filterable),
      query: query,
      include_global: Keyword.get(opts, :include_global)
    }

    {spec, query_ast, expr_defs}
  end

  defp compile_facet(repo, schema, root_binding, query_fn, block, env, ctx, opts) do
    {joins, fields, config, query_ast, expr_defs} = compile_block(block, schema, root_binding, env, ctx)

    facets =
      opts
      |> Keyword.get(:facets, Keyword.get(config, :facets, []))
      |> List.wrap()
      |> MapSet.new()

    if MapSet.size(facets) == 0 do
      raise ArgumentError,
            "defquery type: :facet requires facets: [:field, ...] — columns clients may request via args.field"
    end

    filterable = finalize_queryable(config, :filterable)

    # Register root column sources for facet + filterable fields so filters resolve.
    fields =
      facets
      |> MapSet.union(filterable)
      |> Enum.reduce(fields, fn name, acc ->
        Map.put_new(acc, name, {:column, root_binding, name})
      end)

    query =
      case query_ast do
        nil -> nil
        _ast -> {repo, query_fn, 2}
      end

    spec = %Spec{
      module: nil,
      repo: repo,
      type: :facet,
      schema: schema,
      root_binding: root_binding,
      fields: fields,
      joins: joins,
      filterable: filterable,
      facets: facets,
      query: query,
      include_global: Keyword.get(opts, :include_global)
    }

    {spec, query_ast, expr_defs}
  end

  def query_function_name(query_name), do: :"__query_#{query_name}__"

  def expr_function_name(query_name, field_name), do: :"__expr_#{query_name}_#{field_name}__"

  defp schema(opts, env) do
    case Keyword.get(opts, :schema) do
      nil ->
        Module.get_attribute(env.module, :read_repo_schema) ||
          raise "defquery requires schema: or use Dobro.Infra.Data.ReadRepo, schema: to set a default"

      schema ->
        Macro.expand(schema, env)
    end
  end

  defp compile_block(block, schema, root_binding, env, ctx) do
    expressions =
      case block do
        nil -> []
        {:__block__, _, exprs} -> Enum.reject(exprs, &is_nil/1)
        expr -> [expr]
      end

    Enum.reduce(expressions, {[], %{}, [], nil, []}, fn expr, acc ->
      compile_expression(expr, acc, schema, root_binding, env, ctx)
    end)
  end

  defp compile_expression({:join, _, args}, {joins, fields, config, query_ast, expr_defs}, schema, root_binding, env, ctx) do
    {join_name, opts, join_block} = parse_join_args!(args)
    opts = expand_join_schema_opt(opts, env)
    {opts, on_expr_defs} = compile_join_on_opt(opts, join_name, ctx)
    join_spec = Join.compile!(schema, join_name, root_binding, opts, joins)
    {join_fields, field_config, field_expr_defs} = compile_join_fields(join_block, join_name, ctx)

    if Enum.any?(joins, &(&1.name == join_name)) do
      raise ArgumentError, "duplicate join #{inspect(join_name)} in defquery"
    end

    {
      joins ++ [join_spec],
      Map.merge(fields, join_fields),
      merge_config(config, field_config),
      query_ast,
      expr_defs ++ on_expr_defs ++ field_expr_defs
    }
  end

  defp compile_expression({:field, _, [name, source | field_opts]}, acc, _schema, root_binding, _env, ctx) do
    {joins, fields, config, query_ast, expr_defs} = acc

    cond do
      is_list(source) and Keyword.keyword?(source) ->
        {field_spec, new_defs} = compile_root_field(name, root_binding, source, ctx)
        {joins, Map.put(fields, name, field_spec), merge_field_config(config, name, source), query_ast, expr_defs ++ new_defs}

      true ->
        opts = if is_list(field_opts), do: field_opts, else: []
        {field_spec, new_defs} = compile_root_field(source, root_binding, opts, ctx)
        {joins, Map.put(fields, name, field_spec), merge_field_config(config, name, opts), query_ast, expr_defs ++ new_defs}
    end
  end

  defp compile_expression({:field, _, [name | field_opts]}, acc, _schema, root_binding, _env, ctx) do
    {joins, fields, config, query_ast, expr_defs} = acc
    opts = if is_list(field_opts), do: field_opts, else: []
    {field_spec, new_defs} = compile_root_field(name, root_binding, opts, ctx)
    {joins, Map.put(fields, name, field_spec), merge_field_config(config, name, opts), query_ast, expr_defs ++ new_defs}
  end

  # Shorthand for root columns — each becomes a `field` with filterable/sortable default true.
  defp compile_expression({:fields, _, [fields_list]}, acc, schema, root_binding, env, ctx) do
    Enum.reduce(List.wrap(fields_list), acc, fn name, acc ->
      compile_expression({:field, [], [name]}, acc, schema, root_binding, env, ctx)
    end)
  end

  defp compile_expression({:filterable, _, [fields_list]}, acc, _, _, _, _),
    do: put_queryable(acc, :filterable, fields_list)

  defp compile_expression({:sortable, _, [fields_list]}, acc, _, _, _, _),
    do: put_queryable(acc, :sortable, fields_list)

  defp compile_expression({:facets, _, [fields_list]}, acc, _, _, _, _),
    do: put_config(acc, :facets, List.wrap(fields_list))

  defp compile_expression({:default_order, _, [order]}, acc, _, _, _, _),
    do: put_config(acc, :default_order, order)

  defp compile_expression({:count, _, [mode]}, acc, _, _, _, _),
    do: put_config(acc, :count, mode)

  defp compile_expression({:exclude, _, [fields_list]}, acc, _, _, _, _),
    do: put_config(acc, :exclude, fields_list)

  defp compile_expression({:query, _, [fun]}, {joins, fields, config, _, expr_defs}, _, _, _, _) do
    {joins, fields, config, fun, expr_defs}
  end

  defp compile_expression({:preload, _, args}, acc, _schema, _root_binding, env, _ctx) do
    {joins, fields, config, query_ast, expr_defs} = acc
    {name, schema, opts, block} = parse_preload_args!(args)

    preload = %{
      name: name,
      schema: Macro.expand(schema, env),
      fields: Keyword.get(opts, :fields),
      prefix: Keyword.get(opts, :prefix),
      preloads: compile_preload_block(block, env)
    }

    {joins, fields, Keyword.update(config, :preloads, [preload], &[preload | &1]), query_ast, expr_defs}
  end

  defp compile_expression({:enrich, _, args}, acc, _schema, _root_binding, env, _ctx) do
    {joins, fields, config, query_ast, expr_defs} = acc
    enrich = compile_enrich!(args, env)
    {joins, fields, Keyword.update(config, :enriches, [enrich], &[enrich | &1]), query_ast, expr_defs}
  end

  defp compile_expression(other, _, _, _, _, _) do
    raise "Unsupported query expression: #{Macro.to_string(other)}"
  end

  defp compile_enrich!(args, env) do
    {path, opts} = parse_enrich_args!(args)
    key = Keyword.get(opts, :key) || raise ArgumentError, "enrich requires key:"
    into = Keyword.get(opts, :into) || raise ArgumentError, "enrich requires into:"

    unless is_atom(key) and is_atom(into) do
      raise ArgumentError, "enrich key:/into: must be atoms, got key: #{inspect(key)}, into: #{inspect(into)}"
    end

    %{
      path: path,
      key: key,
      into: into,
      with: compile_enrich_loader!(opts, env)
    }
  end

  defp parse_enrich_args!([path, opts]) when is_atom(path) and is_list(opts) do
    {[path], opts}
  end

  defp parse_enrich_args!([path, opts]) when is_list(path) and is_list(opts) do
    unless Enum.all?(path, &is_atom/1) and path != [] do
      raise ArgumentError, "enrich path must be a non-empty list of atoms, got: #{inspect(path)}"
    end

    {path, opts}
  end

  defp parse_enrich_args!(other) do
    raise ArgumentError,
          "enrich expects `enrich :field, key: ..., into: ..., with: {Mod, :fun}` " <>
            "or `from: {ReadRepo, QueryModule}`, got: #{Macro.to_string({:enrich, [], other})}"
  end

  defp compile_enrich_loader!(opts, env) do
    with_opt = Keyword.get(opts, :with)
    from_opt = Keyword.get(opts, :from)

    case {with_opt, from_opt} do
      {nil, nil} ->
        raise ArgumentError, "enrich requires with: {Mod, :fun} or from: {ReadRepo, QueryModule}"

      {with_opt, nil} ->
        compile_enrich_with!(with_opt, env)

      {nil, from_opt} ->
        compile_enrich_from!(from_opt, env)

      {_, _} ->
        raise ArgumentError, "enrich accepts only one of with: or from:, not both"
    end
  end

  defp compile_enrich_with!({mod, fun}, env) when is_atom(fun) do
    {Macro.expand(mod, env), fun}
  end

  defp compile_enrich_with!({mod, fun, 2}, env) when is_atom(fun) do
    {Macro.expand(mod, env), fun}
  end

  defp compile_enrich_with!(other, _env) do
    raise ArgumentError,
          "enrich with: expects {Module, :function} or {Module, :function, 2}, got: #{inspect(other)}"
  end

  defp compile_enrich_from!({repo, query_module}, env) do
    {:query, Macro.expand(repo, env), Macro.expand(query_module, env)}
  end

  defp compile_enrich_from!(other, _env) do
    raise ArgumentError,
          "enrich from: expects {ReadRepo, QueryModule}, got: #{inspect(other)}"
  end

  defp finalize_enriches(config) do
    config
    |> Keyword.get(:enriches, [])
    |> Enum.reverse()
  end

  defp parse_preload_args!([name, schema]) when is_atom(name) do
    {name, schema, [], nil}
  end

  defp parse_preload_args!([name, schema, [do: block]]) when is_atom(name) do
    {name, schema, [], block}
  end

  defp parse_preload_args!([name, schema, opts]) when is_atom(name) and is_list(opts) do
    {name, schema, opts, nil}
  end

  defp parse_preload_args!([name, schema, opts, [do: block]]) when is_atom(name) and is_list(opts) do
    {name, schema, opts, block}
  end

  defp parse_preload_args!(other) do
    raise ArgumentError,
          "preload expects `preload :assoc, Schema` or `preload :assoc, Schema do`, got: #{Macro.to_string(other)}"
  end

  defp compile_preload_block(nil, _env), do: []

  defp compile_preload_block({:__block__, _, expressions}, env) do
    Enum.map(expressions, fn
      {:preload, _, args} ->
        {name, schema, opts, block} = parse_preload_args!(args)

        %{
          name: name,
          schema: Macro.expand(schema, env),
          fields: Keyword.get(opts, :fields),
          prefix: Keyword.get(opts, :prefix),
          preloads: compile_preload_block(block, env)
        }
    end)
  end

  defp compile_preload_block(expr, env), do: compile_preload_block({:__block__, [], [expr]}, env)

  defp expand_join_schema_opt(opts, env) do
    case Keyword.fetch(opts, :schema) do
      {:ok, schema} -> Keyword.put(opts, :schema, Macro.expand(schema, env))
      :error -> opts
    end
  end

  defp parse_join_args!([join_name, [do: join_block]]) when is_atom(join_name) do
    {join_name, [], join_block}
  end

  defp parse_join_args!([join_name, opts, [do: join_block]]) when is_atom(join_name) and is_list(opts) do
    {join_name, opts, join_block}
  end

  defp parse_join_args!(other) do
    raise ArgumentError,
          "join expects `join :assoc` or `join :assoc, schema: Schema, on: {fk, :id}, type: :left`, got: #{Macro.to_string(other)}"
  end

  # Compile `on: {dynamic(...), :id}` left side into an MFA before Join.compile!.
  defp compile_join_on_opt(opts, join_name, ctx) do
    case Keyword.get(opts, :on) do
      {left, right} when is_atom(left) and is_atom(right) ->
        {opts, []}

      {left_ast, right} when is_atom(right) ->
        fun = expr_function_name(ctx.query_name, :"#{join_name}_on_left")
        opts = Keyword.put(opts, :on, {{:expr, {ctx.repo, fun}}, right})
        {opts, [{fun, left_ast}]}

      nil ->
        {opts, []}

      other ->
        raise ArgumentError,
              "join #{inspect(join_name)} on: expects {left_field | expr, right_field}, got: #{Macro.to_string(other)}"
    end
  end

  defp compile_join_fields(nil, _join_name, _ctx), do: {%{}, [], []}

  defp compile_join_fields({:__block__, _, expressions}, join_name, ctx) do
    Enum.reduce(expressions, {%{}, [], []}, fn
      {:field, _, [name, opts]}, acc when is_list(opts) ->
        if Keyword.keyword?(opts) do
          compile_join_field(name, name, opts, join_name, ctx, acc)
        else
          raise ArgumentError,
                "join field #{inspect(name)} expects keyword options, got: #{inspect(opts)}"
        end

      {:field, _, [name, source | opts]}, acc ->
        opts = if is_list(opts), do: opts, else: []
        compile_join_field(name, source, opts, join_name, ctx, acc)

      {:field, _, [name | opts]}, acc ->
        opts = if is_list(opts), do: opts, else: []
        compile_join_field(name, name, opts, join_name, ctx, acc)
    end)
  end

  defp compile_join_fields(expr, join_name, ctx),
    do: compile_join_fields({:__block__, [], [expr]}, join_name, ctx)

  defp compile_join_field(name, source, opts, join_name, ctx, {fields, config, expr_defs}) do
    config = merge_field_config(config, name, opts)

    case Keyword.get(opts, :expr) do
      nil when is_atom(source) ->
        {Map.put(fields, name, {:join, join_name, source}), config, expr_defs}

      nil ->
        raise ArgumentError,
              "join field #{inspect(name)} source must be an atom column, got: #{inspect(source)}"

      expr_ast ->
        fun = expr_function_name(ctx.query_name, name)
        field_spec = {:join_expr, join_name, {ctx.repo, fun}}
        {Map.put(fields, name, field_spec), config, expr_defs ++ [{fun, expr_ast}]}
    end
  end

  defp compile_root_field(source, root_binding, opts, ctx) when is_atom(source) do
    case Keyword.get(opts, :expr) do
      nil ->
        {{:column, root_binding, source}, []}

      expr_ast ->
        fun = expr_function_name(ctx.query_name, source)
        {{:expr, {ctx.repo, fun}}, [{fun, expr_ast}]}
    end
  end

  # Declared fields are filterable/sortable unless explicitly opted out.
  defp merge_field_config(config, name, opts) do
    config
    |> maybe_append(:filterable, name, Keyword.get(opts, :filterable, true))
    |> maybe_append(:sortable, name, Keyword.get(opts, :sortable, true))
  end

  defp merge_config(config, field_config) do
    Enum.reduce(field_config, config, fn {key, values}, acc ->
      values = List.wrap(values)
      Keyword.update(acc, key, values, &(values ++ &1))
    end)
  end

  defp maybe_append(config, _key, _value, false), do: config

  defp maybe_append(config, key, value, true) do
    Keyword.update(config, key, [value], &(&1 ++ [value]))
  end

  # Top-level filterable/sortable replace per-field defaults when present.
  defp put_queryable({joins, fields, config, query_ast, expr_defs}, key, value) do
    config = Keyword.put(config, explicit_key(key), List.wrap(value))
    {joins, fields, config, query_ast, expr_defs}
  end

  defp put_config({joins, fields, config, query_ast, expr_defs}, key, value) do
    config = Keyword.put(config, key, value)
    {joins, fields, config, query_ast, expr_defs}
  end

  defp finalize_queryable(config, key) do
    case Keyword.get(config, explicit_key(key)) do
      nil -> MapSet.new(Keyword.get(config, key, []))
      list -> MapSet.new(list)
    end
  end

  defp explicit_key(:filterable), do: :filterable_explicit
  defp explicit_key(:sortable), do: :sortable_explicit

  defp apply_exclude(fields, config) do
    case Keyword.get(config, :exclude) do
      nil -> fields
      excluded -> Map.drop(fields, List.wrap(excluded))
    end
  end

  defp ensure_fields!(fields, type) when map_size(fields) == 0 do
    raise ArgumentError,
          "defquery type: #{inspect(type)} requires at least one field — declare with field/1, fields/1, or join field/1"
  end

  defp ensure_fields!(_fields, _type), do: :ok

  defp normalize_default_order!(order) when is_list(order) do
    Enum.map(order, fn
      {dir, field} when dir in [:asc, :desc] and is_atom(field) ->
        {dir, field}

      field when is_atom(field) ->
        {:asc, field}

      other ->
        raise ArgumentError,
              "default_order entries must be atoms or {:asc|:desc, field}, got: #{inspect(other)}"
    end)
  end

  defp normalize_default_order!(other) do
    raise ArgumentError, "default_order must be a keyword/list, got: #{inspect(other)}"
  end

  defp normalize_count!(mode) when mode in [:exact, :estimated, :skip], do: mode

  defp normalize_count!(other) do
    raise ArgumentError,
          "count must be :exact, :estimated, or :skip, got: #{inspect(other)}"
  end
end
