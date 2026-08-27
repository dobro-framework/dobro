defmodule Dobro.AI.ApiToolExecutor do
  @moduledoc """
  Executes AI tool calls against Dobro API routes.
  """

  alias Dobro.AI.ToolContract
  alias Dobro.App.{ExecutionContext, Selection}

  # Unfiltered list calls are treated as a first/sample record lookup (page_size 1).
  # Name filters may return a short disambiguation page, still capped.
  @sample_list_page_size 1
  @filter_list_page_size 5

  @type route_ref :: {module(), atom()}

  @doc """
  Executes a tool call using the route lookup produced by `ApiCatalog.build_tools/1`.

  Options:
  - `:contract_driven` (default `true`) — validate required payload fields from the
    API contract, never infer missing arguments from context, and return `not_found`
    when lookups match no records.
  - `:allowed_tenant_id` — when set, optional `tenant_id` on global-scope routes is
    kept only when it matches this value; when `nil`, optional `tenant_id` is stripped.
  """
  @spec execute(map(), %{String.t() => route_ref()}, ExecutionContext.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def execute(%{function: %{name: name, arguments: arguments}}, routes, execution_context, opts \\ []) do
    contract_driven? = Keyword.get(opts, :contract_driven, true)
    allowed_tenant_id = Keyword.get(opts, :allowed_tenant_id)

    with {:ok, route_ref} <- lookup_route(routes, name),
         {:ok, args} <- decode_arguments(arguments),
         args <- normalize_tool_args(args, execution_context, contract_driven?),
         {execution_context, args} <- apply_selection(name, execution_context, args),
         args <- ensure_query_defaults(name, args),
         args <- enforce_allowed_scope(route_ref, args, allowed_tenant_id, contract_driven?),
         :ok <- validate_contract(contract_driven?, route_ref, args, name) do
      route_ref
      |> apply_route(args, execution_context_for_route(route_ref, execution_context))
      |> encode_api_result(name, args, contract_driven?)
    else
      {:error, {:contract, payload}} -> {:ok, Jason.encode!(payload)}
      {:error, reason} -> {:ok, encode_failure(reason)}
    end
  rescue
    error in Dobro.App.Scope.Error ->
      {:ok, encode_failure(%{reason: :scope_error, message: Exception.message(error)})}

    error ->
      {:ok,
       encode_failure(%{
         reason: :execution_error,
         message: Exception.message(error),
         type: error.__struct__ |> Module.split() |> List.last()
       })}
  end

  defp apply_route({api_module, route_name}, args, execution_context) do
    api_module |> apply(route_name, [args, execution_context])
  catch
    :exit, reason -> {:error, reason}
  end

  defp validate_contract(false, _route_ref, _args, _name), do: :ok

  defp validate_contract(true, route_ref, args, name) do
    case ToolContract.validate_required(args, route_ref) do
      :ok -> :ok
      {:error, fields} -> {:error, {:contract, ToolContract.missing_required_payload(fields, name)}}
    end
  end

  @doc false
  @spec enforce_allowed_scope(route_ref(), map(), integer() | nil, boolean()) :: map()
  def enforce_allowed_scope(route_ref, args, allowed_tenant_id, contract_driven? \\ true)

  def enforce_allowed_scope(route_ref, args, allowed_tenant_id, true) when is_map(args) do
    enforce_optional_tenant_id(route_ref, args, allowed_tenant_id)
  end

  def enforce_allowed_scope(_route_ref, args, _allowed_tenant_id, _contract_driven?), do: args

  @doc false
  @spec display_args(map(), route_ref() | nil, ExecutionContext.t(), keyword()) :: map()
  def display_args(args, route_ref, execution_context, opts \\ []) when is_map(args) do
    contract_driven? = Keyword.get(opts, :contract_driven, true)
    allowed_tenant_id = Keyword.get(opts, :allowed_tenant_id)

    with {:ok, atom_args} <- decode_arguments(args) do
      atom_args
      |> normalize_tool_args(execution_context, contract_driven?)
      |> maybe_clamp_displayed_query(route_ref)
      |> then(fn normalized ->
        case route_ref do
          nil -> normalized
          ref -> enforce_allowed_scope(ref, normalized, allowed_tenant_id, contract_driven?)
        end
      end)
      |> stringify_keys()
    else
      _ -> stringify_keys(args)
    end
  end

  defp enforce_optional_tenant_id(route_ref, args, allowed_tenant_id) do
    if "tenant_id" in ToolContract.required_fields(route_ref) do
      args
    else
      case Map.get(args, :tenant_id) do
        ^allowed_tenant_id when not is_nil(allowed_tenant_id) ->
          args

        _ ->
          Map.delete(args, :tenant_id)
      end
    end
  end

  defp encode_api_result({:ok, result}, name, args, contract_driven?) do
    if contract_driven? and ToolContract.classify_success(result, name) == :not_found do
      args_json = args |> stringify_keys() |> Map.new()
      {:ok, Jason.encode!(ToolContract.not_found_payload(name, args_json))}
    else
      {:ok, Jason.encode!(normalize_result(result))}
    end
  end

  defp encode_api_result({:error, errors}, _name, _args, _contract_driven?) when is_list(errors) do
    {:ok, Jason.encode!(%{ok: false, errors: Enum.map(errors, &encode_error/1)})}
  end

  defp encode_api_result({:error, error}, _name, _args, _contract_driven?) do
    {:ok, Jason.encode!(%{ok: false, error: encode_error(error)})}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  def encode_failure({:unknown_tool, name}) do
    Jason.encode!(%{ok: false, error: %{reason: :unknown_tool, tool: name}})
  end

  def encode_failure(reason) do
    Jason.encode!(%{ok: false, error: encode_error(reason)})
  end

  defp encode_error(%Dobro.Error{} = error), do: Map.from_struct(error)
  defp encode_error(error) when is_map(error), do: error
  defp encode_error(error), do: %{reason: error}

  defp lookup_route(routes, name) do
    case Map.fetch(routes, name) do
      {:ok, route_ref} -> {:ok, route_ref}
      :error -> {:error, {:unknown_tool, name}}
    end
  end

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, args} when is_map(args) -> {:ok, atomize_keys(args)}
      {:ok, _} -> {:error, :invalid_tool_arguments}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_arguments(args) when is_map(args), do: {:ok, atomize_keys(args)}
  defp decode_arguments(_), do: {:error, :invalid_tool_arguments}

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {atomize_key(key), atomize_value(value)} end)
  end

  defp atomize_value(value) when is_map(value), do: atomize_keys(value)

  defp atomize_value(value) when is_list(value) do
    Enum.map(value, fn
      item when is_map(item) -> atomize_keys(item)
      item -> item
    end)
  end

  defp atomize_value(value), do: value

  defp atomize_key(key) when is_atom(key), do: key

  defp atomize_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> String.to_atom(key)
    end
  end

  @doc false
  @spec normalize_tool_args(map(), ExecutionContext.t(), boolean()) :: map()
  def normalize_tool_args(args, execution_context, contract_driven? \\ true)

  def normalize_tool_args(args, _execution_context, true) when is_map(args) do
    coerce_tenant_id_field(args)
  end

  def normalize_tool_args(args, execution_context, false) when is_map(args) do
    args
    |> coerce_tenant_id_field()
    |> maybe_fill_tenant_id(execution_context)
  end

  def normalize_tool_args(args, _execution_context, _contract_driven?), do: args

  @doc false
  @spec cache_key_for_tool(String.t(), map(), ExecutionContext.t()) :: String.t()
  def cache_key_for_tool(name, args, execution_context) when is_map(args) and is_binary(name) do
    args
    |> normalize_tool_args(execution_context, true)
    |> cache_key_subset(name)
    |> maybe_put_selection(args)
    |> sorted_map()
    |> Jason.encode!()
  end

  defp maybe_put_selection(subset, args) when is_map(args) do
    case Map.get(args, :selection) || Map.get(args, "selection") do
      selection when is_map(selection) -> Map.put(subset, :selection, selection)
      _ -> subset
    end
  end

  # When tenant scope is on the execution context, always use that id for tool calls.
  defp maybe_fill_tenant_id(args, %ExecutionContext{tenant: %{id: tenant_id}})
       when is_map(args) and is_integer(tenant_id) do
    Map.put(args, :tenant_id, tenant_id)
  end

  defp maybe_fill_tenant_id(args, _execution_context), do: args

  defp coerce_tenant_id_field(args) when is_map(args) do
    case Map.get(args, :tenant_id) do
      id when is_binary(id) ->
        case Integer.parse(id) do
          {parsed, ""} -> Map.put(args, :tenant_id, parsed)
          _ -> args
        end

      _ ->
        args
    end
  end

  defp ensure_query_defaults(name, args) when is_binary(name) and is_map(args) do
    if list_tool?(name), do: clamp_list_query(args), else: args
  end

  defp ensure_query_defaults(_tool_name, args), do: args

  defp list_tool?(name) when is_binary(name) do
    String.match?(name, ~r/(?:^|_)list(?:_|$)/)
  end

  defp clamp_list_query(args) when is_map(args) do
    query = list_query_map(args)
    max = list_page_cap(query)

    query =
      query
      |> clamp_int_field(:page_size, max)
      |> clamp_int_field(:limit, max)
      |> force_first_page()
      |> default_page_size()

    Map.put(args, :query, query)
  end

  defp list_query_map(args) do
    case Map.get(args, :query) do
      query when is_map(query) -> query
      _ -> %{}
    end
  end

  defp list_page_cap(query) when is_map(query) do
    case Map.get(query, :filters) || Map.get(query, "filters") do
      filters when is_list(filters) and filters != [] -> @filter_list_page_size
      _ -> @sample_list_page_size
    end
  end

  defp clamp_int_field(query, field, max) do
    string = Atom.to_string(field)

    cond do
      Map.has_key?(query, field) -> Map.update!(query, field, &clamp_positive(&1, max))
      Map.has_key?(query, string) -> Map.update!(query, string, &clamp_positive(&1, max))
      true -> query
    end
  end

  defp clamp_positive(value, max) when is_integer(value) and value > max, do: max
  defp clamp_positive(value, _max) when is_integer(value) and value > 0, do: value

  defp clamp_positive(value, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> clamp_positive(int, max)
      _ -> max
    end
  end

  defp clamp_positive(_value, max), do: max

  defp force_first_page(query) when is_map(query) do
    query
    |> Map.put(:page, 1)
    |> Map.delete("page")
  end

  defp default_page_size(query) when is_map(query) do
    if query_has_size?(query) do
      query
    else
      Map.put(query, :page_size, @sample_list_page_size)
    end
  end

  defp query_has_size?(query) do
    present?(query, :page_size) or present?(query, "page_size") or present?(query, :limit) or
      present?(query, "limit")
  end

  defp present?(map, key), do: not is_nil(Map.get(map, key))

  defp maybe_clamp_displayed_query(args, {_mod, route}) when is_atom(route) do
    ensure_query_defaults(Atom.to_string(route), args)
  end

  defp maybe_clamp_displayed_query(args, _route_ref), do: args

  @doc false
  @spec apply_selection(String.t(), ExecutionContext.t(), map()) :: {ExecutionContext.t(), map()}
  def apply_selection(name, %ExecutionContext{} = execution_context, args)
      when is_binary(name) and is_map(args) do
    {selection, args} = pop_selection(args)

    # List tools may project id/name for discovery. Get/detail must return the
    # full record — a field selection would project to a map and skip preloads.
    execution_context =
      if list_tool?(name) do
        case build_selection(selection) do
          nil -> execution_context
          %Selection{} = built -> %{execution_context | selection: built}
        end
      else
        execution_context
      end

    {execution_context, args}
  end

  defp pop_selection(args) do
    case Map.pop(args, :selection) do
      {nil, args} ->
        case Map.pop(args, "selection") do
          {nil, args} -> {nil, args}
          {selection, args} -> {selection, args}
        end

      {selection, args} ->
        {selection, args}
    end
  end

  defp build_selection(nil), do: nil

  defp build_selection(%{"fields" => fields}) when is_list(fields) and fields != [] do
    %Selection{fields: field_set(fields)}
  end

  defp build_selection(%{fields: fields}) when is_list(fields) and fields != [] do
    %Selection{fields: field_set(fields)}
  end

  defp build_selection(_), do: nil

  defp field_set(fields) do
    fields
    |> Enum.map(&field_atom/1)
    |> MapSet.new()
  end

  defp field_atom(name) when is_binary(name) do
    try do
      String.to_existing_atom(name)
    rescue
      ArgumentError -> String.to_atom(name)
    end
  end

  defp field_atom(name) when is_atom(name), do: name

  defp cache_key_subset(args, "tenant_management_archive_list_imports") do
    query = Map.get(args, :query, %{})
    query_for_cache = Map.drop(query, [:page, :page_size, "page", "page_size"])

    args
    |> Map.take([:tenant_id])
    |> Map.put(:query, query_for_cache)
  end

  defp cache_key_subset(args, "tenant_management_archive_list_entries") do
    query = Map.get(args, :query) || %{}
    query_for_cache = Map.drop(query, [:page, :page_size, "page", "page_size"])
    %{query: query_for_cache}
  end

  defp cache_key_subset(args, "tenant_management_archive_get_entry"), do: Map.take(args, [:id])
  defp cache_key_subset(args, _name), do: args

  defp sorted_map(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new()
  end

  @doc false
  @spec execution_context_for_route(route_ref(), ExecutionContext.t()) :: ExecutionContext.t()
  def execution_context_for_route({api_module, route_name}, %ExecutionContext{} = execution_context) do
    if global_scope_route?(api_module, route_name) do
      strip_tenant(execution_context)
    else
      execution_context
    end
  end

  defp global_scope_route?(api_module, route_name) do
    case route_definition_module(api_module, route_name) do
      nil ->
        false

      mod ->
        Code.ensure_loaded(mod)

        function_exported?(mod, :__scope__, 0) and match?({:global, nil}, mod.__scope__())
    end
  end

  defp route_definition_module(api_module, route_name) do
    Code.ensure_loaded(api_module)

    query_mod =
      if function_exported?(api_module, :__queries__, 1) do
        case api_module.__queries__(route_name) do
          {mod, _} when is_atom(mod) -> mod
          _ -> nil
        end
      end

    command_mod =
      if is_nil(query_mod) and function_exported?(api_module, :__commands__, 1) do
        case api_module.__commands__(route_name) do
          {mod, _} when is_atom(mod) -> mod
          _ -> nil
        end
      end

    query_mod || command_mod
  end

  defp strip_tenant(%ExecutionContext{} = execution_context) do
    %ExecutionContext{execution_context | tenant: nil}
  end

  # Encode tool results for Jason. Calendar/decimal types must NOT be Map.from_struct'd
  # (that exposes microsecond tuples like {0, 0} which Jason cannot encode).
  defp normalize_result(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_result(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_result(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_result(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_result(%Decimal{} = value), do: Decimal.to_string(value)

  defp normalize_result(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> normalize_result()
  end

  defp normalize_result(%{} = map) do
    Map.new(map, fn {key, value} -> {key, normalize_result(value)} end)
  end

  defp normalize_result(list) when is_list(list), do: Enum.map(list, &normalize_result/1)
  defp normalize_result(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> normalize_result()
  defp normalize_result(other), do: other
end
