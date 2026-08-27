defmodule Dobro.App.Api.Surface do
  @moduledoc """
  Discovers API modules registered against `Dobro.App.Api.Port`, filtered by surface.

  Extension packages (dobro_graphql, dobro_ai, …) register surface atoms via `register/1`.
  API modules opt in via `surfaces:` on `use Dobro.App.Api`.
  """

  @doc """
  Returns API modules registered for the given surface at runtime.
  """
  @spec apis(atom()) :: [module()]
  def apis(surface) when is_atom(surface) do
    Dobro.Config.adapter_registry!().resolve_all(Dobro.App.Api.Port, surface: surface)
  end

  @doc """
  Returns surface atoms registered by extension packages.
  """
  @spec registered() :: [atom()]
  def registered do
    Application.get_env(:dobro, :api_surfaces, [])
  end

  @doc false
  defmacro register(surface) when is_atom(surface) do
    quote do
      surfaces = Application.get_env(:dobro, :api_surfaces, [])

      unless unquote(surface) in surfaces do
        Application.put_env(:dobro, :api_surfaces, surfaces ++ [unquote(surface)])
      end
    end
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

    registry_mod
    .registry()
    |> Enum.filter(fn {port, for_criteria, _mod} ->
      port == Dobro.App.Api.Port and surface in Keyword.get(for_criteria, :surfaces, [])
    end)
    |> Enum.map(fn {_port, _for, mod} -> mod end)
    |> Enum.uniq()
  end
end
