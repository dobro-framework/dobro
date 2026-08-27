if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.DobroGraphql.Install do
    @shortdoc "Installs Dobro GraphQL (Absinthe) into a project"

    @moduledoc """
    #{@shortdoc}

    Should be called with `mix igniter.install dobro_graphql`.

    Creates or patches an Absinthe schema that imports Dobro API surfaces.
    Requires Phoenix + Absinthe (e.g. a project created with `phx.new`).
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :dobro,
        schema: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      base = Igniter.Project.Module.module_name_prefix(igniter)
      web = Module.concat(base, Web)
      schema = Module.concat(web, Schema)

      igniter
      |> ensure_schema(schema)
      |> Igniter.add_notice("""
      Dobro GraphQL installed.

      Point Absinthe at #{inspect(schema)}, and ensure your Dobro APIs declare
      `surfaces: [:graphql]`. New APIs from `mix dobro.gen.bc` already do.
      """)
    end

    defp ensure_schema(igniter, schema) do
      case Igniter.Project.Module.module_exists(igniter, schema) do
        {true, igniter} ->
          Igniter.Project.Module.find_and_update_module!(igniter, schema, fn zipper ->
            case Igniter.Code.Common.move_to_do_block(zipper) do
              {:ok, zipper} ->
                {:ok,
                 Igniter.Code.Common.add_code(zipper, """
                 # Dobro GraphQL surfaces — add `api YourApp.YourBc.YourApi` inside ApiSchema
                 defmodule ApiSchema do
                   use Dobro.Graphql.Schema
                 end

                 import_types ApiSchema
                 """)}

              :error ->
                {:ok, zipper}
            end
          end)

        {false, igniter} ->
          Igniter.Project.Module.create_module(igniter, schema, """
          @moduledoc \"\"\"
          Absinthe schema with Dobro GraphQL API surfaces.
          \"\"\"
          use Absinthe.Schema

          defmodule ApiSchema do
            use Dobro.Graphql.Schema
            # api MyApp.Catalog.Products.ProductsApi
          end

          import_types Absinthe.Type.Custom
          import_types AbsintheErrorPayload.ValidationMessageTypes
          import_types ApiSchema

          query do
            # Placeholder until Dobro APIs contribute fields; Absinthe requires ≥1 field.
            field :health, :string do
              resolve(fn _, _ -> {:ok, "ok"} end)
            end
          end

          mutation do
            field :_noop, :boolean do
              resolve(fn _, _ -> {:ok, true} end)
            end
          end
          """)
      end
    end
  end
else
  defmodule Mix.Tasks.DobroGraphql.Install do
    @moduledoc "Installs Dobro GraphQL (Absinthe) into a project"
    @shortdoc @moduledoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'dobro_graphql.install' requires igniter.
      See https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
