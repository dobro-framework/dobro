defmodule Dobro.App.Api.Surface do
  @moduledoc """
  Discovers API modules and routes registered against `Dobro.App.Api.Port`,
  filtered by surface.

  Extension packages (dobro_graphql, dobro_ai, …) and hosts register surface
  atoms via `register/1` before discovery. API modules opt in via `surfaces:`
  on `use Dobro.App.Api`; individual routes may extend that set with their own
  `surfaces:` option.
  """

  @doc """
  Returns API modules registered for the given surface at runtime.

  Raises if `surface` has not been `register/1`'d.
  """
  @spec apis(atom()) :: [module()]
  def apis(surface) when is_atom(surface) do
    assert_registered!(surface)
    Dobro.Config.adapter_registry!().resolve_all(Dobro.App.Api.Port, surface: surface)
  end

  @doc """
  Returns query routes whose effective surfaces include `surface`.

  Keys are stable `namespace.route_name` strings (for example
  `funeral_planning.get_case`). Values are `{api_module, route_name}`.

  Scans all API modules on `Dobro.App.Api.Port` so route-only surface opt-ins
  are found even when the API adapter was registered under a different surface
  (e.g. `:graphql`).

  Raises if `surface` has not been `register/1`'d.
  """
  @spec routes(atom()) :: %{String.t() => {module(), atom()}}
  def routes(surface) when is_atom(surface) do
    assert_registered!(surface)

    Dobro.Config.adapter_registry!().resolve_all(Dobro.App.Api.Port)
    |> Enum.uniq()
    |> Enum.flat_map(&query_routes_for_api(&1, surface))
    |> Map.new()
  end

  @doc """
  Returns command routes whose effective surfaces include `surface`.

  Keys and values match `routes/1` (`namespace.route_name` → `{api, route}`).
  Raises if `surface` has not been `register/1`'d.
  """
  @spec command_routes(atom()) :: %{String.t() => {module(), atom()}}
  def command_routes(surface) when is_atom(surface) do
    assert_registered!(surface)

    Dobro.Config.adapter_registry!().resolve_all(Dobro.App.Api.Port)
    |> Enum.uniq()
    |> Enum.flat_map(&command_routes_for_api(&1, surface))
    |> Map.new()
  end

  @doc """
  Returns surface atoms registered by extension packages / hosts.
  """
  @spec registered() :: [atom()]
  def registered do
    Application.get_env(:dobro, :api_surfaces, [])
  end

  @doc "Whether `surface` has been registered."
  @spec known?(atom()) :: boolean()
  def known?(surface) when is_atom(surface), do: surface in registered()

  @doc """
  Raises `ArgumentError` unless `surface` is in `registered/0`.
  """
  @spec assert_registered!(atom()) :: :ok
  def assert_registered!(surface) when is_atom(surface) do
    if known?(surface) do
      :ok
    else
      raise ArgumentError,
            "unknown API surface #{inspect(surface)}; registered: #{inspect(registered())}. " <>
              "Call Dobro.App.Api.Surface.register/1 (typically from Application.start) before discovery."
    end
  end

  @doc """
  Records a surface atom (e.g. `:graphql`, `:ai`, `:rules`) in application env.

  Must be a function, not a quoting macro. Expanding `Application.get_env/3`
  into a consumer module body triggers Elixir's compile_env warning, and
  `Application.compile_env/3` is unsafe here because this key is also written
  with `put_env/3`.
  """
  @spec register(atom()) :: :ok
  def register(surface) when is_atom(surface) do
    surfaces = Application.get_env(:dobro, :api_surfaces, [])

    unless surface in surfaces do
      Application.put_env(:dobro, :api_surfaces, surfaces ++ [surface])
    end

    :ok
  end

  @doc """
  Expands `api/1` calls for every module opted into `surface` at compile time.
  """
  defmacro apis_ast(surface) when is_atom(surface) do
    modules = modules_for_surface(surface)

    for mod <- modules do
      quote do
        api(unquote(mod))
      end
    end
  end

  @doc false
  @spec modules_for_surface(atom()) :: [module()]
  def modules_for_surface(surface) when is_atom(surface) do
    registry_mod = Dobro.Config.adapter_registry!()

    registry_mod.registry()
    |> Enum.filter(fn {port, for_criteria, _mod} ->
      port == Dobro.App.Api.Port and surface in Keyword.get(for_criteria, :surfaces, [])
    end)
    |> Enum.map(fn {_port, _for, mod} -> mod end)
    |> Enum.uniq()
  end

  defp query_routes_for_api(api_module, surface) do
    surface_routes(api_module, surface, :__queries__)
  end

  defp command_routes_for_api(api_module, surface) do
    surface_routes(api_module, surface, :__commands__)
  end

  defp surface_routes(api_module, surface, export) do
    Code.ensure_compiled!(api_module)

    if function_exported?(api_module, export, 0) do
      namespace = namespace_for_context(api_module.__context__())

      apply(api_module, export, [])
      |> Enum.filter(fn {_name, {_mod, opts}} ->
        surface in Keyword.get(opts, :surfaces, [])
      end)
      |> Enum.map(fn {route_name, _entry} ->
        {"#{namespace}.#{route_name}", {api_module, route_name}}
      end)
    else
      []
    end
  end

  defp namespace_for_context({_context, namespace}), do: to_string(namespace)

  defp namespace_for_context(context) when is_atom(context) do
    context
    |> Module.split()
    |> Enum.slice(1..-1//1)
    |> Enum.map_join("_", &String.downcase/1)
  end

  defp namespace_for_context(_), do: "unknown"
end
