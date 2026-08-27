defmodule Dobro.Infra.Data.Query.StrategyOpts do
  @moduledoc false

  alias Dobro.Infra.Data.Query.Spec
  alias Dobro.Infra.Data.ReadRepo.Context

  @spec build(module(), Context.t() | nil, Spec.t()) :: keyword()
  def build(repo_module, context, %Spec{} = spec) do
    base =
      if tenant_context_mode?(repo_module) and match?(%Context{}, context) do
        [context: context]
      else
        []
      end

    include_global =
      case Map.get(spec, :include_global) do
        nil -> default_include_global(repo_module)
        value -> value
      end

    case include_global do
      nil -> base
      value -> Keyword.put(base, :include_global, value)
    end
  end

  defp default_include_global(repo_module) do
    if function_exported?(repo_module, :__query_defaults__, 0) do
      repo_module.__query_defaults__()
      |> Keyword.get(:include_global)
    end
  end

  defp tenant_context_mode?(repo_module) do
    function_exported?(repo_module, :context_mode, 0) &&
      repo_module.context_mode() == :tenant
  end
end
