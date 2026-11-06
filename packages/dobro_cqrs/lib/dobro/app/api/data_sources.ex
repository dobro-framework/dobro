defmodule Dobro.App.Api.DataSources do
  @moduledoc """
  Resolves named data sources against API query routes opted into a given
  surface (for example `:rules`).

  Route keys are `namespace.route_name`, for example
  `funeral_planning.get_case`. Argument templates may bind:

  - `"$subject.id"` / `"$subject.type"`
  - `"$tenant.id"`
  - `"$event.<path>"` — dotted path into the event payload binding

  Discovery uses `Dobro.App.Api.Surface.routes/1`; the surface must be
  `Surface.register/1`'d first.
  """

  alias Dobro.App.Api.Surface
  alias Dobro.App.ExecutionContext
  alias Dobro.Error

  @type route_ref :: {module(), atom()}
  @type sources :: %{optional(String.t()) => map()}
  @type bindings :: map()
  @type memo :: %{{String.t(), map()} => map()}

  @doc """
  Data-source routes for `surface`, keyed by stable route key.
  """
  @spec routes(atom()) :: %{String.t() => route_ref()}
  def routes(surface) when is_atom(surface), do: Surface.routes(surface)

  @doc """
  Metadata for admin pickers: key, API module, route name, and argument fields.
  """
  @spec catalog(atom()) :: [map()]
  def catalog(surface) when is_atom(surface) do
    routes(surface)
    |> Enum.map(fn {key, {api, route}} ->
      {query_mod, opts} = api.__queries__(route)

      %{
        key: key,
        api: api,
        route: route,
        description: Keyword.get(opts, :description) || query_mod.__description__(),
        argument_fields: argument_fields(query_mod)
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Resolves `sources` against `bindings`, reusing `memo` entries and `registry`.

  Returns `{:ok, %{name => normalised_map}, memo}` or `{:error, reason}`.
  """
  @spec resolve(sources(), bindings(), ExecutionContext.t(), memo(), %{
          String.t() => route_ref()
        }) ::
          {:ok, %{String.t() => map()}, memo()} | {:error, term()}
  def resolve(sources, bindings, %ExecutionContext{} = ctx, memo, registry)
      when is_map(sources) and is_map(bindings) and is_map(memo) and is_map(registry) do
    Enum.reduce_while(sources, {:ok, %{}, memo}, fn {name, source}, {:ok, acc, memo} ->
      name = to_string(name)

      case resolve_one(source, bindings, ctx, memo, registry) do
        {:ok, result, memo} -> {:cont, {:ok, Map.put(acc, name, result), memo}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_one(source, bindings, ctx, memo, registry) do
    with {:ok, route_key, args} <- source_parts(source),
         {:ok, route_ref} <- fetch_route(registry, route_key),
         bound <- bind_args(args, bindings),
         memo_key = {route_key, bound} do
      case Map.fetch(memo, memo_key) do
        {:ok, cached} ->
          {:ok, cached, memo}

        :error ->
          case call(route_ref, bound, ctx) do
            {:ok, result} ->
              normalised = normalize_result(result)
              {:ok, normalised, Map.put(memo, memo_key, normalised)}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp source_parts(%{route: route} = source) when is_binary(route) do
    {:ok, route, Map.get(source, :args) || Map.get(source, "args") || %{}}
  end

  defp source_parts(%{"route" => route} = source) when is_binary(route) do
    {:ok, route, Map.get(source, "args") || Map.get(source, :args) || %{}}
  end

  defp source_parts(_), do: {:error, Error.new(:invalid_data_source, description: "route is required")}

  defp fetch_route(registry, route_key) do
    case Map.fetch(registry, route_key) do
      {:ok, ref} -> {:ok, ref}
      :error -> {:error, Error.new(:unknown_data_source, description: route_key)}
    end
  end

  defp call({api, route}, args, ctx) do
    apply(api, route, [args, ctx])
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  def bind_args(args, bindings) when is_map(args) do
    Map.new(args, fn {key, value} -> {atomize_key(key), bind_value(value, bindings)} end)
  end

  def bind_args(_args, _bindings), do: %{}

  defp bind_value("$subject.id", bindings), do: get_in_binding(bindings, ["subject", "id"])
  defp bind_value("$subject.type", bindings), do: get_in_binding(bindings, ["subject", "type"])
  defp bind_value("$tenant.id", bindings), do: get_in_binding(bindings, ["tenant", "id"])

  defp bind_value("$event." <> path, bindings) do
    get_in_binding(bindings, ["event" | String.split(path, ".")])
  end

  defp bind_value(value, bindings) when is_map(value), do: bind_args(value, bindings)

  defp bind_value(value, bindings) when is_list(value) do
    Enum.map(value, &bind_value(&1, bindings))
  end

  defp bind_value(value, _bindings), do: value

  defp get_in_binding(bindings, path) when is_map(bindings) do
    Enum.reduce_while(path, bindings, fn key, acc ->
      cond do
        not is_map(acc) ->
          {:halt, nil}

        Map.has_key?(acc, key) ->
          {:cont, Map.get(acc, key)}

        is_binary(key) and Map.has_key?(acc, String.to_atom(key)) ->
          {:cont, Map.get(acc, String.to_atom(key))}

        true ->
          {:halt, nil}
      end
    end)
  end

  defp get_in_binding(_bindings, _path), do: nil

  defp argument_fields(query_module) do
    Code.ensure_loaded(query_module)

    cond do
      function_exported?(query_module, :__fields__, 0) ->
        Enum.map(query_module.__fields__(), &to_string/1)

      function_exported?(query_module, :__schema__, 0) ->
        query_module.__schema__()
        |> Enum.map(fn {name, {_type, _opts}} -> to_string(name) end)

      true ->
        []
    end
  rescue
    _ -> []
  end

  defp atomize_key(key) when is_atom(key), do: key

  defp atomize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> String.to_atom(key)
  end

  @doc false
  def normalize_result(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize_result(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def normalize_result(%Date{} = value), do: Date.to_iso8601(value)
  def normalize_result(%Time{} = value), do: Time.to_iso8601(value)
  def normalize_result(%Decimal{} = value), do: Decimal.to_string(value)

  def normalize_result(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> normalize_result()
  end

  def normalize_result(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_result(value)} end)
  end

  def normalize_result(list) when is_list(list), do: Enum.map(list, &normalize_result/1)

  def normalize_result(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> normalize_result()
  end

  def normalize_result(other), do: other
end
