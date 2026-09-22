defmodule Dobro.Infra.Data.Query.FacetRunner do
  @moduledoc false

  import Ecto.Query

  alias Dobro.Infra.Data.Query.{Spec, StrategyOpts}
  alias Dobro.Query.Facet

  def run(repo_module, %Spec{} = spec, args, context) do
    ecto_query = build_queryable(repo_module, spec, args, context)
    strategy_opts = StrategyOpts.build(repo_module, context, spec)

    Facet.run(ecto_query, args, spec,
      repo: repo_module,
      strategy_opts: strategy_opts
    )
  end

  defp build_queryable(_repo_module, spec, args, context) do
    case spec.query do
      {mod, fun, 2} ->
        apply(mod, fun, [args, context])

      nil ->
        from(s in spec.schema, as: ^spec.root_binding)
    end
  end
end
