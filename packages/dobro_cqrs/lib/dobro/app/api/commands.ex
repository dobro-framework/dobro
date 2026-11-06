defmodule Dobro.App.Api.Commands do
  @moduledoc """
  Runs named command routes opted into a given surface (for example `:actions`).

  Route keys are `namespace.route_name`, for example `tasks.ensure_task`.
  Argument templates may bind:

  - `"$subject.id"` / `"$subject.type"`
  - `"$tenant.id"`
  - `"$event.<path>"` — dotted path into the event payload binding

  Discovery uses `Dobro.App.Api.Surface.command_routes/1`; the surface must be
  `Surface.register/1`'d first.
  """

  alias Dobro.App.Api.{DataSources, Surface}
  alias Dobro.App.ExecutionContext
  alias Dobro.Error

  @type route_ref :: {module(), atom()}
  @type bindings :: map()

  @doc """
  Command routes for `surface`, keyed by stable route key.
  """
  @spec routes(atom()) :: %{String.t() => route_ref()}
  def routes(surface) when is_atom(surface), do: Surface.command_routes(surface)

  @doc """
  Metadata for admin pickers: key, API module, route name, and argument fields.
  """
  @spec catalog(atom()) :: [map()]
  def catalog(surface) when is_atom(surface) do
    routes(surface)
    |> Enum.map(fn {key, {api, route}} ->
      {command_mod, opts} = api.__commands__(route)

      %{
        key: key,
        api: api,
        route: route,
        description: Keyword.get(opts, :description) || command_mod.__description__(),
        argument_fields: argument_fields(command_mod)
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Binds `arguments` against `bindings` and invokes the command route.

  Pass `routes(surface)` (or a test stub) as `registry`.
  """
  @spec run(String.t(), map(), bindings(), ExecutionContext.t(), %{String.t() => route_ref()}) ::
          :ok | {:error, term()}
  def run(command_key, arguments, bindings, %ExecutionContext{} = ctx, registry)
      when is_binary(command_key) and is_map(registry) do
    with {:ok, route_ref} <- fetch_route(registry, command_key),
         bound <- DataSources.bind_args(arguments || %{}, bindings),
         {:ok, _result} <- call(route_ref, bound, ctx) do
      :ok
    end
  end

  defp fetch_route(registry, route_key) do
    case Map.fetch(registry, route_key) do
      {:ok, ref} -> {:ok, ref}
      :error -> {:error, Error.new(:unknown_command, description: route_key)}
    end
  end

  defp call({api, route}, args, ctx) do
    apply(api, route, [args, ctx])
  catch
    :exit, reason -> {:error, reason}
  end

  defp argument_fields(command_module) do
    Code.ensure_loaded(command_module)

    cond do
      function_exported?(command_module, :__fields__, 0) ->
        Enum.map(command_module.__fields__(), &to_string/1)

      function_exported?(command_module, :__schema__, 0) ->
        command_module.__schema__()
        |> Enum.map(fn {name, {_type, _opts}} -> to_string(name) end)

      true ->
        []
    end
  rescue
    _ -> []
  end
end
