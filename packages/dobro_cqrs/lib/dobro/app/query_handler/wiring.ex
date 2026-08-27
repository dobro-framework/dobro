defmodule Dobro.App.QueryHandler.Wiring do
  @moduledoc false

  alias Dobro.App.ScopePolicy

  defmacro __before_compile__(env) do
    handles = Module.get_attribute(env.module, :query_handles) || []
    port_or_repo = Module.get_attribute(env.module, :query_handler_repo)

    if port_or_repo do
      repo_impl = repo_implementation(port_or_repo)

      handles
      |> Enum.reverse()
      |> Enum.each(fn {query_module, _repo_fn} ->
        ScopePolicy.validate_wiring!(query_module, repo_impl, env)
      end)
    end

    :ok
  end

  defp repo_implementation(port_or_repo) do
    cond do
      function_exported?(port_or_repo, :__allowed_scopes__, 0) ->
        port_or_repo

      function_exported?(port_or_repo, :adapter, 0) ->
        Dobro.Config.adapter_registry!().resolve!(port_or_repo, [])

      function_exported?(port_or_repo, :adapter, 1) ->
        Dobro.Config.adapter_registry!().resolve!(port_or_repo, [])

      true ->
        port_or_repo
    end
  end
end
