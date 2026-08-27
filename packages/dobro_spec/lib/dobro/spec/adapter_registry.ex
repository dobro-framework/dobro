defmodule Dobro.Spec.AdapterRegistry do
  @moduledoc """
  Registry for adapters
  """
  defmacro __using__(_opts \\ []) do
    quote do
      Module.register_attribute(__MODULE__, :__registry__, accumulate: true)
      import Dobro.Spec.AdapterRegistry
      @before_compile Dobro.Spec.AdapterRegistry
    end
  end

  @doc """
  Registers an adapter
  """
  defmacro register(module_ast) do
    module = Macro.expand(module_ast, __CALLER__)

    quote do
      for port <- unquote(module).__ports__() do
        Module.put_attribute(
          __MODULE__,
          :__registry__,
          {port, unquote(module).__for__(port), unquote(module)}
        )
      end
    end
  end

  @doc """
  Registers a child adapter registry
  """
  defmacro register_child(module_ast) do
    quote do
      Module.put_attribute(__MODULE__, :__registry__, {:child_registry, unquote(module_ast)})
    end
  end

  @doc """
  Before compile macro
  """
  defmacro __before_compile__(_env) do
    quote do
      def registry, do: unquote(__MODULE__).registry(@__registry__)

      @doc """
      Resolves all adapters for a given port
      """
      def resolve_all(port, opts \\ []),
        do: unquote(__MODULE__).resolve_all(@__registry__, port, opts)

      def resolve!(port, opts \\ []),
        do: unquote(__MODULE__).resolve!(@__registry__, port, opts)
    end
  end

  def registry(entries) do
    flatten_registry(entries)
  end

  def resolve_all(entries, port, opts \\ []) do
    surface = Keyword.get(opts, :surface)

    entries
    |> registry()
    |> Enum.filter(fn {p, for_criteria, _} ->
      p == port and surface_matches?(for_criteria, surface)
    end)
    |> Enum.map(fn {_, _, mod} -> mod end)
  end

  defp surface_matches?(_for_criteria, nil), do: true

  defp surface_matches?(for_criteria, surface) do
    surface in Keyword.get(for_criteria, :surfaces, [])
  end

  def resolve!(entries, port, opts \\ []) do
    case Application.get_env(Dobro.Config.otp_app(), port) do
      nil -> resolve_for!(entries, port, opts)
      adapter when is_atom(adapter) -> adapter
      opts when is_list(opts) -> resolve_for!(entries, port, opts)
    end
  end

  defp resolve_for!(entries, port, opts) do
    case find_adapter(entries, port, opts) do
      {:ok, mod} -> mod
      :error -> raise "No adapter found for #{inspect(port)} (#{inspect(opts)})"
    end
  end

  defp find_adapter(entries, port, opts) do
    match = port.__match__()
    adapter_for = Keyword.get(opts, :for, [])

    entries
    |> registry()
    |> Enum.find(fn {p, f, _} -> p == port and (is_nil(match) or match.(f, adapter_for)) end)
    |> case do
      {_, _, mod} -> {:ok, mod}
      nil -> :error
    end
  end

  defp flatten_registry(entries) do
    Enum.flat_map(entries, fn
      {:child_registry, mod} -> mod.registry()
      {port, for, mod} -> [{port, for, mod}]
    end)
  end
end
