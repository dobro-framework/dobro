defmodule Dobro.Infra.Data.Query.Definition do
  @moduledoc """
  DSL for defining read-repository queries.

      defquery GetCategory, type: :one do
        fields [:id, :name, :identifier, :tenant_id]
        preload :tenant, TenantSchema, fields: [:id, :name]
      end

      defquery GetEntry, type: :one do
        fields [:id, :tenant_id, :data, :name, :import_id]

        preload :import, ImportSchema do
          preload :mapping, MappingSchema
        end
      end

      defquery ListCategories, type: :list do
        fields [:id, :name, :identifier, :tenant_id]

        join :tenant, type: :left do
          field :tenant_name, :name
        end

        join :region, through: :tenant do
          field :region_name, :name
        end

        field :name_upper,
          expr: dynamic([category: c], fragment("upper(?)", c.name))

        query fn args, _context ->
          from(c in schema(), as: :category)
          |> maybe_apply_tenant(args[:tenant_id], include_global: true)
        end
      end

  `:list` and `:one` queries must declare their projected fields with `field/1`,
  `fields/1`, and/or join `field/1`. Declared fields are filterable and sortable
  by default; pass `filterable: false` / `sortable: false` to opt out, or use
  top-level `filterable [...]` / `sortable [...]` to replace the allow-lists.

  Options:

  - `:type` — `:one`, `:list`, or `:exists` (required)
  - `:as` — repo function name. Defaults to `Macro.underscore` of the query
    module name (`ListCategories` → `:list_categories`); `:exists` queries append
    `?` (`CategoryExists` → `:category_exists?`). Pass an atom to override, or
    `false` / `nil` to skip defining a repo function.
  - `:binding` — override root Ecto binding (default: inferred from schema, e.g. `CategorySchema` → `:category`)
  - `:schema` — override schema when not set on `use ReadRepo`
  - `:id_field` — for `:one` queries, the args key used to look up the record (default: `:id`)
  - `:include_global` — for `:one`, `:list`, and `:exists` queries with a tenant-id strategy, forwarded to the tenant filter
  - `:default_limit` — default page size for `:list` queries (default: `10`)
  - `:default_order` — default sort when the client omits `order_by`, e.g. `[asc: :id]`
  - `:count` — list total strategy: `:exact` (default), `:estimated` (Postgres planner rows), or `:skip`

  Per-query options override defaults set on `use ReadRepo` via `query_defaults:`.

  Joins resolve from Ecto associations on the source schema. Use `through:` to join
  associations on an earlier join binding (e.g. `through: :tenant` chains onto `:tenant`).
  """

  alias Dobro.Infra.Data.Query.Compiler

  defmacro __using__(_opts) do
    quote do
      import Dobro.Infra.Data.Query.Definition, only: [defquery: 2, defquery: 3]
    end
  end

  @doc """
  Defines a named query on the read repository.

  Creates a nested module (e.g. `GetCategory`) with `__spec__/0`, and a repo
  function named from the module (`get_category/1`, or `category_exists?/1` for
  `:exists`) unless `:as` overrides or disables it.

  The `do` block is optional when the query needs no field/join/query
  declarations — for example a default `:exists` check against the repo schema:

      defquery OfficeExistsForTenant, type: :exists
  """
  defmacro defquery(name, opts, do: block) when is_list(opts) do
    expand_defquery(name, opts, block, __CALLER__)
  end

  defmacro defquery(name, opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :do) ->
        raise ArgumentError,
              "defquery requires a :type option, e.g. defquery MyQuery, type: :list do"

      Keyword.has_key?(opts, :type) ->
        expand_defquery(name, opts, nil, __CALLER__)

      true ->
        raise ArgumentError,
              "defquery requires a :type option, e.g. defquery MyQuery, type: :exists"
    end
  end

  defp expand_defquery(name, opts, block, env) do
    repo = env.module
    opts = merge_query_opts(repo, opts)
    type = Keyword.fetch!(opts, :type)
    query_module = query_module_name(repo, name)
    query_name = query_module |> Module.split() |> List.last() |> String.to_atom()
    function_name = resolve_as(opts, query_name, type)

    ensure_schema_compiled!(env)

    {spec, query_ast, expr_defs} = Compiler.compile(type, query_name, opts, block, env)
    spec = %{spec | module: query_module}

    query_fn = Compiler.query_function_name(query_name)

    query_def =
      case query_ast do
        nil ->
          nil

        fun_ast ->
          quote do
            def unquote(query_fn)(args, context) do
              (unquote(fun_ast)).(args, context)
            end
          end
      end

    expr_defs_ast =
      Enum.map(expr_defs, fn {fun, expr_ast} ->
        quote do
          def unquote(fun)() do
            unquote(expr_ast)
          end
        end
      end)

    function_def =
      case function_name do
        nil ->
          nil

        name when is_atom(name) ->
          quote do
            def unquote(name)(args, context \\ nil) do
              run(unquote(query_module), args, context)
            end
          end
      end

    quote location: :keep do
      defmodule unquote(query_module) do
        @moduledoc false

        @spec __spec__() :: Dobro.Infra.Data.Query.Spec.t()
        def __spec__, do: unquote(Macro.escape(spec))
      end

      unquote(query_def)
      unquote_splicing(expr_defs_ast)
      unquote(function_def)
    end
  end

  defp resolve_as(opts, query_name, type) do
    case Keyword.fetch(opts, :as) do
      :error -> default_as(query_name, type)
      {:ok, false} -> nil
      {:ok, nil} -> nil
      {:ok, name} when is_atom(name) -> name
    end
  end

  defp default_as(query_name, type) do
    base =
      query_name
      |> Atom.to_string()
      |> Macro.underscore()

    case type do
      :exists -> String.to_atom(base <> "?")
      _ -> String.to_atom(base)
    end
  end

  defp query_module_name(repo, {:__aliases__, _, parts}) do
    case parts do
      [single] when is_atom(single) -> Module.concat(repo, single)
      _ -> Module.concat(parts)
    end
  end

  defp query_module_name(repo, name) when is_atom(name), do: Module.concat(repo, name)

  defp ensure_schema_compiled!(env) do
    case Module.get_attribute(env.module, :read_repo_schema) do
      nil -> :ok
      schema -> Code.ensure_compiled!(schema)
    end
  end

  defp merge_query_opts(repo, opts) do
    defaults =
      case Module.get_attribute(repo, :read_repo_query_defaults) do
        nil -> []
        defaults when is_list(defaults) -> defaults
      end

    Enum.reduce(defaults, opts, fn {key, default}, acc ->
      if Keyword.has_key?(acc, key), do: acc, else: Keyword.put(acc, key, default)
    end)
  end
end
