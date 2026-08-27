defmodule Dobro.Infra.Data.Query.ListRunner do
  @moduledoc false

  import Ecto.Query

  alias Dobro.Infra.Data.Query.{Helpers, Spec, StrategyOpts}
  alias Dobro.Query.List
  alias Dobro.Query.Params

  def run(repo_module, %Spec{} = spec, args, context, opts \\ []) do
    selection = Helpers.selection(context)
    params = args |> Map.get(:query) |> Params.normalize_query()
    ecto_query = build_queryable(repo_module, spec, args, context)
    strategy_opts = StrategyOpts.build(repo_module, context, spec)

    List.run(
      ecto_query,
      params,
      spec,
      Keyword.merge(
        [
          repo: repo_module,
          strategy_opts: strategy_opts,
          selection: selection
        ],
        opts
      )
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
