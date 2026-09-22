defmodule Dobro.Infra.Data.Query.Runner do
  @moduledoc """
  Executes compiled read-repository query definitions.
  """

  alias Dobro.Infra.Data.Mappings
  alias Dobro.Infra.Data.Query.{Exists, FacetRunner, ListRunner, One}

  @doc """
  Runs `query_module` defined on `repo_module` with `args` and optional context.

  Selection is read from `context.selection` when present.
  """
  @spec run(module(), module(), map(), term()) :: term()
  def run(repo_module, query_module, args, context \\ nil) do
    spec = query_module.__spec__()

    result =
      case spec.type do
        :one -> One.run(repo_module, spec, args, context)
        :list -> ListRunner.run(repo_module, spec, args, context)
        :exists -> Exists.run(repo_module, spec, args, context)
        :facet -> FacetRunner.run(repo_module, spec, args, context)
      end

    apply_mappings(repo_module, result, spec.type)
  end

  defp apply_mappings(repo_module, {:ok, result}, :one) do
    {:ok, Mappings.apply_to_result(result, repo_mappings(repo_module))}
  end

  defp apply_mappings(repo_module, {:ok, %{entries: entries} = page}, :list) when is_list(entries) do
    mappings = repo_mappings(repo_module)

    {:ok,
     %{page | entries: Enum.map(entries, &Mappings.apply_to_result(&1, mappings))}}
  end

  defp apply_mappings(_repo_module, other, _type), do: other

  defp repo_mappings(repo_module) do
    if function_exported?(repo_module, :__mappings__, 0) do
      repo_module.__mappings__()
    else
      Mappings.empty()
    end
  end
end
