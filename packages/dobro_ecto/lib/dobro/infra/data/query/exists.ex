defmodule Dobro.Infra.Data.Query.Exists do
  @moduledoc false

  alias Dobro.Infra.Data.Query.{Spec, StrategyOpts}

  def run(repo_module, %Spec{} = spec, args, context) do
    strategy_opts = StrategyOpts.build(repo_module, context, spec)

    spec
    |> queryable(args, context)
    |> exists(repo_module, strategy_opts)
  end

  defp queryable(%Spec{query: {mod, fun, 2}}, args, context), do: apply(mod, fun, [args, context])
  defp queryable(%Spec{schema: schema}, _args, _context), do: schema

  defp exists(queryable, repo_module, strategy_opts) do
    if function_exported?(repo_module, :exists?, 2) do
      repo_module.exists?(queryable, strategy_opts)
    else
      Dobro.Infra.Repo.exists?(queryable, strategy_opts)
    end
  end
end
