defmodule Dobro.Graphql.Schema do
  @moduledoc """
  Macros and helpers for generating Absinthe schema definitions from Dobro APIs.

  Provides `api/1` to expand commands and queries from an API module, plus
  `api_mutation/2` and `api_query/2` for individual operations.
  """

  alias Dobro.Graphql.Helpers.{Errors, Mutation}
  alias Dobro.Graphql.Schema.MutationBuilder
  alias Dobro.Schema.{OneOf, OneOfBy, OneOfInput, Types}
  use Absinthe.Schema.Notation

  defmacro __using__(opts \\ []) do
    auto_apis = Keyword.get(opts, :auto_apis, true)
    mod = __CALLER__.module

    auto_api_blocks =
      if auto_apis do
        # Run at expansion time so get_env/put_env are not injected into the caller.
        Dobro.App.Api.Surface.register(:graphql)

        for api_mod <- Dobro.App.Api.Surface.modules_for_surface(:graphql) do
          quote do
            api(unquote(api_mod))
          end
        end
      else
        []
      end

    Module.register_attribute(mod, :referenced_types, accumulate: true)
    Module.register_attribute(mod, :api_modules, accumulate: true)

    quote location: :keep do
      import Dobro.Graphql.Schema
      import AbsintheErrorPayload.Payload

      @before_compile {unquote(__MODULE__), :__before_compile__}

      use Absinthe.Schema.Notation

      unquote_splicing(auto_api_blocks)
    end
  end

  defmacro api(api_module) do
    api_module = Macro.expand(api_module, __CALLER__)
    Module.put_attribute(__CALLER__.module, :api_modules, api_module)
    Code.ensure_compiled(api_module)

    commands = api_module.__commands__()
    queries = api_module.__queries__()

    graphql_mutations =
      commands
      |> Enum.map(fn {command_fn, _} ->
        quote location: :keep do
          api_mutation(unquote(api_module), unquote(command_fn))
        end
      end)

    graphql_queries =
      queries
      |> Enum.map(fn {query_fn, _} ->
        quote do
          api_query(unquote(api_module), unquote(query_fn))
        end
      end)

    quote do
      unquote_splicing(graphql_mutations)
      unquote_splicing(graphql_queries)
    end
  end

  defmacro __before_compile__(env) do
    api_modules = Module.get_attribute(env.module, :api_modules)
    context_map = context_map_for(api_modules)

    referenced_types =
      env.module
      |> Module.get_attribute(:referenced_types)
      |> Enum.uniq()
      |> dedupe_referenced_types()

    type_blocks =
      Enum.map(referenced_types, fn {type_mod, gql_type} ->
        build_type(env.module, type_mod, context_map: context_map, gql_type: gql_type)
      end)

    quote do
      unquote_splicing(type_blocks)

      def __referenced_types__, do: @referenced_types
    end
  end

  # Drop plain :result/:input registrations when a specialized :union/:enum/
  # :union_input/:one_of_input entry exists for the same module. Keep both
  # :input and :result when both are needed (they generate distinct Absinthe types).
  defp dedupe_referenced_types(referenced_types) do
    specialized_keys =
      referenced_types
      |> Enum.filter(fn
        {{:one_of_input, _, _}, :one_of_input} -> true
        {_, gql} when gql in [:union, :union_input, :enum] -> true
        _ -> false
      end)
      |> MapSet.new(fn
        {{:one_of_input, type_name, _}, _} -> {:one_of_input, type_name}
        {type_mod, _} -> type_mod
      end)

    referenced_types
    |> Enum.reject(fn
      {{:one_of_input, type_name, _}, gql} when gql in [:result, :input] ->
        MapSet.member?(specialized_keys, {:one_of_input, type_name})

      {type_mod, gql} when gql in [:result, :input] ->
        MapSet.member?(specialized_keys, type_mod)

      _ ->
        false
    end)
    |> Enum.uniq()
  end

  def namespace_for(module_or_atom, context_map) do
    Code.ensure_compiled(module_or_atom)

    if Code.ensure_loaded?(module_or_atom) do
      module_parts = module_or_atom |> Module.split()

      match =
        context_map
        |> Enum.find(fn {context, _} ->
          List.starts_with?(module_parts, context |> Module.split())
        end)

      case match do
        {_, namespace} ->
          namespace

        nil ->
          nil
      end
    end
  end

  def schema_for(module) do
    Code.ensure_compiled(module)

    if function_exported?(module, :__schema__, 0) do
      module.__schema__()
    else
      nil
    end
  end

  def schema_for!(module) do
    case schema_for(module) do
      nil -> raise "#{module} does not provide a __schema__"
      schema -> schema
    end
  end

  def type_from_schema(mod, %Dobro.Schema.ListOf{of_type: of_type}, context_map, gql_type) do
    list_of_type = type_from_schema(mod, of_type, context_map, gql_type)

    quote do
      list_of(unquote(list_of_type))
    end
  end

  def type_from_schema(mod, %Dobro.Schema.NonNull{of_type: of_type}, context_map, gql_type) do
    inner_type = type_from_schema(mod, of_type, context_map, gql_type)

    quote do
      non_null(unquote(inner_type))
    end
  end

  def type_from_schema(mod, %OneOfInput{variants: variants} = one_of_input, context_map, gql_type) do
    unless gql_type == :input do
      raise ArgumentError,
            "one_of_input/1 is only supported for GraphQL inputs, got: #{inspect(gql_type)}"
    end

    one_of_input_type_from_schema(mod, one_of_input, variants, context_map)
  end

  def type_from_schema(mod, %Dobro.Schema.OneOf{of_types: of_types}, context_map, :input) do
    variants = Enum.map(of_types, fn type -> {OneOf.member_key(type), type} end)
    one_of_input_type_from_schema(mod, OneOfInput.new(variants), variants, context_map)
  end

  def type_from_schema(_mod, %Dobro.Schema.OneOf{}, _context_map, gql_type) do
    raise ArgumentError,
          "inline one_of/2 is only supported for GraphQL inputs (use a named Dobro.Schema.OneOf module for results), got: #{inspect(gql_type)}"
  end

  def type_from_schema(mod, %Dobro.Schema.OneOfBy{of_types: of_types}, context_map, :input) do
    variants = Enum.map(of_types, fn type -> {OneOf.member_key(type), type} end)
    one_of_input_type_from_schema(mod, OneOfInput.new(variants), variants, context_map)
  end

  def type_from_schema(_mod, %Dobro.Schema.OneOfBy{}, _context_map, gql_type) do
    raise ArgumentError,
          "inline OneOfBy is only supported for GraphQL inputs (use a named Dobro.Schema.OneOfBy module for results), got: #{inspect(gql_type)}"
  end

  def type_from_schema(_, :map, _, _), do: :json
  def type_from_schema(_, :any, _, _), do: :json

  def type_from_schema(mod, type, context_map, gql_type) when is_atom(type) do
    cond do
      type in Types.types() ->
        type

      json_scalar_module?(type) ->
        :json

      Dobro.Enum.enum?(type) ->
        enum_type_from_schema(mod, type, context_map)

      OneOf.one_of?(type) or OneOfBy.one_of_by?(type) ->
        union_type_from_schema(mod, type, context_map, gql_type)

      one_of_input_module?(type) ->
        type_from_schema(mod, type.__one_of_input__(), context_map, gql_type)

      true ->
        module_type_from_schema(mod, type, context_map, gql_type)
    end
  end

  def type_from_schema(_mod, type, _context_map, _gql_type) do
    raise ArgumentError, "unsupported GraphQL schema type: #{inspect(type)}"
  end

  # Modules that intentionally map to the Absinthe JSON scalar (opaque JSON values).
  defp json_scalar_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__graphql_json__, 0) and
      module.__graphql_json__()
  end

  defp one_of_input_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__one_of_input__, 0)
  end

  defp enum_type_from_schema(mod, type, context_map) do
    remember_referenced_type(mod, {type, :enum})
    type_namespace = namespace_for(type, context_map)
    name_for([type_namespace, name_from_module(type)])
  end

  defp union_type_from_schema(mod, type, context_map, :result) do
    remember_referenced_type(mod, {type, :union})

    Enum.each(union_member_types(type), fn member ->
      _ = module_type_from_schema(mod, member, context_map, :result)
    end)

    type_namespace = namespace_for(type, context_map)
    name_for([type_namespace, name_from_module(type)])
  end

  defp union_type_from_schema(mod, type, context_map, :input) do
    # Input-position one_ofs are encoded as GraphQL `@oneOf` input objects.
    if type_already_referenced?(mod, type, :union_input) do
      type_namespace = namespace_for(type, context_map)
      name_for([type_namespace, name_from_module(type), "input"])
    else
      remember_referenced_type(mod, {type, :union_input})
      variants = union_keyed_variants(type)

      Enum.each(variants, fn {_name, member} ->
        _ = module_type_from_schema(mod, member, context_map, :input)
      end)

      type_namespace = namespace_for(type, context_map)
      name_for([type_namespace, name_from_module(type), "input"])
    end
  end

  defp union_type_from_schema(_mod, _type, _context_map, gql_type) do
    raise ArgumentError,
          "Dobro.Schema.OneOf/OneOfBy is only supported for GraphQL :result or :input, got: #{inspect(gql_type)}"
  end

  defp union_member_types(type) do
    cond do
      OneOf.one_of?(type) -> type.__one_of_types__()
      OneOfBy.one_of_by?(type) -> type.__one_of_by_types__()
    end
  end

  defp union_keyed_variants(type) do
    cond do
      OneOf.one_of?(type) -> OneOf.keyed_variants(type)
      OneOfBy.one_of_by?(type) -> OneOfBy.keyed_variants(type)
    end
  end

  defp one_of_input_type_from_schema(mod, one_of_input, variants, context_map) do
    type_name = one_of_input_type_name(variants, context_map)
    remember_referenced_type(mod, {{:one_of_input, type_name, one_of_input}, :one_of_input})

    Enum.each(variants, fn {_name, variant_type} ->
      _ = type_from_schema(mod, variant_type, context_map, :input)
    end)

    type_name
  end

  defp one_of_input_type_name(variants, context_map) do
    variant_part =
      variants
      |> Enum.map(fn {name, type} ->
        type_ns = if is_atom(type), do: namespace_for(type, context_map), else: nil
        type_name = if is_atom(type), do: name_from_module(type), else: "value"
        [type_ns, type_name, name] |> Enum.reject(&is_nil/1) |> Enum.join("_")
      end)
      |> Enum.join("_or_")

    name_for(["one_of", variant_part])
  end

  def module_type_from_schema(mod, type, context_map, gql_type) when is_atom(type) do
    mod_name = name_from_module(type)
    type_namespace = namespace_for(type, context_map)
    suffix = if gql_type == :input, do: "input", else: nil

    # Short-circuit recursive registrations (e.g. DependencyGroup → DependencyNode → …).
    if type_already_referenced?(mod, type, gql_type) do
      name_for([type_namespace, mod_name, suffix])
    else
      remember_referenced_type(mod, {type, gql_type})

      # Register nested
      # credo:disable-for-next-line Credo.Check.Design.TagTODO
      # todo: Improve performance by changing to post-processor in before_compile?
      sub_schema = schema_for(type)
      if sub_schema, do: fields_from_schema(mod, sub_schema, context_map, gql_type)

      name_for([type_namespace, mod_name, suffix])
    end
  end

  defp type_already_referenced?(mod, type, gql_type) do
    try do
      (Module.get_attribute(mod, :referenced_types) || [])
      |> Enum.any?(fn
        {^type, ^gql_type} -> true
        _ -> false
      end)
    rescue
      # Runtime tests may call type_from_schema/build_type outside compilation.
      ArgumentError -> false
    end
  end

  defp remember_referenced_type(mod, entry) do
    try do
      Module.put_attribute(mod, :referenced_types, entry)
    rescue
      ArgumentError -> :ok
    end
  end

  defp fields_from_schema(mod, schema, context_map, gql_type) do
    for {name, {field_type, opts}} <- schema do
      required = Keyword.get(opts, :required, false)
      field_description = Keyword.get(opts, :description)
      absinthe_type = type_from_schema(mod, field_type, context_map, gql_type)

      field_type_ast =
        field_absinthe_type(absinthe_type, field_type, required)

      field_declaration(name, field_type_ast, field_description)
    end
  end

  defp field_declaration(name, type_ast, nil) do
    quote do
      field unquote(name), unquote(type_ast)
    end
  end

  defp field_declaration(name, type_ast, description) when is_binary(description) do
    quote do
      field unquote(name), unquote(type_ast) do
        description(unquote(description))
      end
    end
  end

  defp effective_description(route_opts, query_or_command_module) do
    case Keyword.get(route_opts, :description) do
      description when is_binary(description) -> description
      _ -> query_or_command_module.__description__()
    end
  end

  defp field_description_block(nil), do: nil

  defp field_description_block(description) when is_binary(description) do
    quote do
      description(unquote(description))
    end
  end

  defp field_absinthe_type(absinthe_type, %Dobro.Schema.NonNull{}, _required), do: absinthe_type

  defp field_absinthe_type(absinthe_type, _field_type, true) do
    quote do
      non_null(unquote(absinthe_type))
    end
  end

  defp field_absinthe_type(absinthe_type, _field_type, false), do: absinthe_type

  defmacro api_mutation(api_module, command_fn) do
    mod = __CALLER__.module

    api_module = api_module |> Macro.expand(__CALLER__)
    Code.ensure_compiled!(api_module)

    modules = MutationBuilder.command_modules(api_module, command_fn)
    context_map = context_map_for(api_module)

    names =
      MutationBuilder.names(
        api_module,
        modules.command_module,
        modules.result_module,
        context_map
      )

    %{
      payload_module: payload_module,
      identity_module: identity_module,
      result_module: result_module,
      scope: scope,
      command_module: command_module
    } =
      modules

    {_command_module, command_opts} = api_module.__commands__(command_fn)
    field_description_block =
      field_description_block(effective_description(command_opts, command_module))

    input_schema = if payload_module, do: schema_for!(payload_module), else: []
    identity_schema = if identity_module, do: schema_for!(identity_module), else: []

    input_block =
      if input_schema == [],
        do: nil,
        else: fields_from_schema(mod, input_schema, context_map, :input)

    identity_block =
      if identity_schema == [],
        do: nil,
        else: fields_from_schema(mod, identity_schema, context_map, :input)

    result_block = fields_from_schema(mod, schema_for!(result_module), context_map, :result)

    scope_block = MutationBuilder.scope_block(scope)

    input_block_object =
      if input_block || identity_block do
        quote do
          input_object unquote(names.input_name) do
            unquote(identity_block)
            unquote(input_block)
            unquote(scope_block)
          end
        end
      end

    arg_object =
      if input_block || identity_block do
        quote do
          arg(:input, non_null(unquote(names.input_name)))
        end
      end

    quote do
      unquote(require_schema_module(command_module))
      unquote(require_schema_module(payload_module))
      unquote(require_schema_module(identity_module))
      unquote(require_schema_module(result_module))
      unquote(input_block_object)

      object unquote(names.result_name) do
        unquote(result_block)
      end

      payload_object(unquote(names.payload_name), unquote(names.result_name))

      extend object(:mutation) do
        field unquote(names.field_name), type: unquote(names.payload_name) do
          unquote(field_description_block)
          unquote(arg_object)

          resolve(fn
            _parent, %{input: input}, %{context: context} ->
              unquote(api_module).unquote(command_fn)(input, context)
              |> Mutation.payload()

            _parent, _, %{context: context} ->
              unquote(api_module).unquote(command_fn)(%{}, context)
              |> Mutation.payload()
          end)

          middleware(&build_mutation_payload/2)
          middleware(&build_payload/2)
        end
      end
    end
  end

  #
  # Set result as value (via Mutation.payload) and expose events to the context
  # @todo: Add ability to filter events to propagate / differentiate between domain and system/integration events
  # (in command handler)
  def build_mutation_payload(
        %{value: %{result: result, events: events}} = resolution,
        _
      ) do
    resolution
    |> Map.put(:value, result)
    |> Map.put(:context, Map.merge(resolution.context, %{events: events}))
  end

  def build_mutation_payload(resolution, _) do
    resolution
  end

  def apply_selection(resolution, result_module) do
    selection = Dobro.Graphql.Selection.from_resolution(resolution, result_module)

    context =
      case resolution.context do
        %Dobro.App.ExecutionContext{} = execution_context ->
          Dobro.App.ExecutionContext.new(Map.put(Map.from_struct(execution_context), :selection, selection))

        context when is_map(context) ->
          Map.put(context, :selection, selection)
      end

    %{resolution | context: context}
  end

  def build_type(mod, type_mod, opts \\ []) do
    gql_type = Keyword.get(opts, :gql_type, :result)
    context_map = Keyword.get(opts, :context_map, %{})

    cond do
      gql_type == :one_of_input ->
        build_one_of_input_type(mod, type_mod, context_map)

      gql_type == :union_input ->
        Code.ensure_compiled(type_mod)
        build_union_input_type(mod, type_mod, context_map)

      gql_type == :union or
          (is_atom(type_mod) and (OneOf.one_of?(type_mod) or OneOfBy.one_of_by?(type_mod)) and
             gql_type != :input) ->
        Code.ensure_compiled(type_mod)
        build_union_type(type_mod, context_map)

      gql_type == :enum or (is_atom(type_mod) and Dobro.Enum.enum?(type_mod)) ->
        Code.ensure_compiled(type_mod)
        build_enum_type(type_mod, context_map)

      true ->
        Code.ensure_compiled(type_mod)
        build_object_type(mod, type_mod, gql_type, context_map)
    end
  end

  defp build_enum_type(type_mod, context_map) do
    namespace = namespace_for(type_mod, context_map)
    type_name = name_for([namespace, name_from_module(type_mod)])
    description = type_mod.description()

    value_blocks =
      Enum.map(type_mod.values(), fn value_name ->
        opts = Map.get(type_mod.value_opts(), value_name, [])
        value_description = Keyword.get(opts, :description)

        if value_description do
          quote do
            _ = value(unquote(value_name), description: unquote(value_description))
          end
        else
          quote do
            _ = value(unquote(value_name))
          end
        end
      end)

    enum_body =
      if description do
        quote do
          _ = description(unquote(description))
          unquote_splicing(value_blocks)
        end
      else
        quote do
          unquote_splicing(value_blocks)
        end
      end

    quote do
      enum unquote(type_name) do
        unquote(enum_body)
      end
    end
  end

  defp build_object_type(mod, type_mod, gql_type, context_map) do
    suffix = if gql_type == :input, do: "input", else: nil
    namespace = namespace_for(type_mod, context_map)
    type_name = name_for([namespace, name_from_module(type_mod), suffix])
    fields = fields_from_schema(mod, schema_for!(type_mod), context_map, gql_type)

    case gql_type do
      :input ->
        quote do
          input_object unquote(type_name) do
            unquote(fields)
          end
        end

      :result ->
        quote do
          object unquote(type_name) do
            unquote(fields)
          end
        end
    end
  end

  defp build_union_type(type_mod, context_map) do
    namespace = namespace_for(type_mod, context_map)
    type_name = name_for([namespace, name_from_module(type_mod)])
    escaped_context_map = Macro.escape(context_map)

    member_names =
      Enum.map(union_member_types(type_mod), fn member ->
        member_ns = namespace_for(member, context_map)
        name_for([member_ns, name_from_module(member)])
      end)

    quote do
      union unquote(type_name) do
        types(unquote(member_names))

        resolve_type(fn value, _resolution ->
          case unquote(type_mod).resolve_type(value) do
            nil ->
              nil

            member_mod ->
              member_ns =
                Dobro.Graphql.Schema.namespace_for(member_mod, unquote(escaped_context_map))

              Dobro.Graphql.Schema.name_for([
                member_ns,
                Dobro.Graphql.Schema.name_from_module(member_mod)
              ])
          end
        end)
      end
    end
  end

  defp build_one_of_input_type(mod, {:one_of_input, type_name, %OneOfInput{variants: variants}}, context_map) do
    build_exclusive_input_object(mod, type_name, variants, context_map)
  end

  defp build_union_input_type(mod, union_mod, context_map) do
    namespace = namespace_for(union_mod, context_map)
    type_name = name_for([namespace, name_from_module(union_mod), "input"])
    variants = union_keyed_variants(union_mod)
    build_exclusive_input_object(mod, type_name, variants, context_map)
  end

  defp build_exclusive_input_object(mod, type_name, variants, context_map) do
    fields =
      Enum.map(variants, fn {name, variant_type} ->
        absinthe_type = type_from_schema(mod, variant_type, context_map, :input)

        quote do
          field unquote(name), unquote(absinthe_type)
        end
      end)

    quote do
      input_object unquote(type_name) do
        # Absinthe `directive/1` returns a unique_integer ref (put_attr/2); discard it.
        _ = directive(:one_of)
        unquote_splicing(fields)
      end
    end
  end

  defmacro register_type(type_mod, opts \\ []) do
    mod = __CALLER__.module
    build_type(mod, Macro.expand(type_mod, __CALLER__), opts)
  end

  def types_for(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__types__, 0),
      do: module.__types__(),
      else: []
  end

  def namespace_for_context({_context, namespace}) do
    namespace
  end

  def namespace_for_context(context) do
    context
    |> Module.split()
    |> Enum.slice(1..-1//1)
    |> Enum.map_join("_", &String.downcase/1)
  end

  def module_prefix_for_context({context, _namespace}) do
    context
  end

  def module_prefix_for_context(context) do
    context
  end

  def context_map_for(api_modules) when is_list(api_modules) do
    api_modules
    |> Enum.map(fn module -> context_map_for(module) end)
    |> Enum.reduce(%{}, fn map1, map2 -> Map.merge(map1, map2) end)
  end

  def context_map_for(module) when is_atom(module) do
    context_config = module.__context__()
    module_prefix = module_prefix_for_context(context_config)
    namespace = namespace_for_context(context_config)
    [{module_prefix, namespace}] |> Map.new()
  end

  defmacro api_query(api_module, query_fn) do
    mod = __CALLER__.module

    api_module = api_module |> Macro.expand(__CALLER__)
    context_map = context_map_for(api_module)

    api_namespace = namespace_for(api_module, context_map)

    {query_module, query_opts} = api_module.__queries__(query_fn)

    if query_module == nil,
      do:
        raise(
          "query_module is missing: #{api_module}.#{query_fn}. Available: #{inspect(api_module.__queries__() |> Keyword.keys())}"
        )

    result_module = Keyword.fetch!(query_opts, :result)
    query_namespace = namespace_for(query_module, context_map)

    query_name = name_from_module(query_module)
    field_name = name_for([api_namespace, query_name])
    input_name = name_for([query_namespace, query_name, "input"])
    input_schema = schema_for!(query_module)

    input_block =
      if input_schema == [],
        do: nil,
        else: fields_from_schema(mod, input_schema, context_map, :input)

    # `result_module` may be a "type expression" (e.g. `result(list_of(...))`)
    # rather than a module atom, in which case it won't have a `__schema__/0`.
    result_schema = if is_atom(result_module), do: schema_for(result_module), else: nil

    {result_object, result_type} =
      if result_schema do
        result_name = name_for([query_namespace, query_name, "result"])

        result_block = fields_from_schema(mod, result_schema, context_map, :result)

        {
          quote do
            object unquote(result_name) do
              unquote(result_block)
            end
          end,
          result_name
        }
      else
        # Non-module result types (e.g. `result(list_of(...))`) should be rendered via
        # `type_from_schema/4` instead of trying to derive a namespace from them.
        {nil, type_from_schema(mod, result_module, context_map, :result)}
      end

    input_block_object =
      if input_block do
        quote do
          input_object unquote(input_name) do
            unquote(input_block)
          end
        end
      end

    arg_object =
      if input_block do
        quote do
          arg(:input, non_null(unquote(input_name)))
        end
      end

    selection_middleware =
      if result_schema do
        quote do
          middleware(fn resolution, _config ->
            Dobro.Graphql.Schema.apply_selection(resolution, unquote(result_module))
          end)
        end
      end

    field_description_block =
      field_description_block(effective_description(query_opts, query_module))

    quote do
      unquote(require_schema_module(query_module))
      unquote(require_schema_module(result_module))
      unquote(input_block_object)
      unquote(result_object)

      extend object(:query) do
        field unquote(field_name), type: unquote(result_type) do
          unquote(field_description_block)
          unquote(arg_object)
          unquote(selection_middleware)

          resolve(fn
            _parent, %{input: input}, %{context: context} ->
              unquote(api_module).unquote(query_fn)(input, context)
              |> Errors.format()

            _parent, _, %{context: context} ->
              unquote(api_module).unquote(query_fn)(%{}, context)
              |> Errors.format()
          end)
        end
      end
    end
  end

  def name_from_module(module) do
    parts = Module.split(module)

    case Enum.reverse(parts) do
      ["Result", parent | _] -> Macro.underscore(parent) <> "_result"
      [name | _] -> Macro.underscore(name)
    end
  end

  def name_for(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join("_") |> String.to_atom()

  # Keep a compile-time dependency so payload/result changes rebuild the GraphQL schema.
  defp require_schema_module(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) do
      quote do
        require unquote(module)
      end
    end
  end

  defp require_schema_module(_module), do: nil
end
