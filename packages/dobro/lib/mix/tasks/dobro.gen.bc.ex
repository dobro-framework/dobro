if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Dobro.Gen.Bc do
    @shortdoc "Generates a Dobro bounded context skeleton"

    @moduledoc """
    #{@shortdoc}

        mix dobro.gen.bc MyApp.Catalog.Products

    Creates ports/domain/app/infra folders, an API module, a BC adapter registry,
    and registers the BC under the application root `AdapterRegistry`.

    ## Options

    * `--tenant` — use schema-per-tenant repo strategy in generated adapters (default false)
    """

    use Igniter.Mix.Task

    alias Dobro.Igniter.Naming

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :dobro,
        schema: [tenant: :boolean],
        defaults: [tenant: false],
        positional: [:bounded_context]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      bc_module =
        igniter.args.positional[:bounded_context]
        |> List.wrap()
        |> List.first()
        |> to_string()
        |> Igniter.Project.Module.parse()

      base = Igniter.Project.Module.module_name_prefix(igniter)
      root_registry = Module.concat(base, AdapterRegistry)
      bc_parts = Module.split(bc_module)
      context_atom = Naming.context_atom(bc_parts)
      api = Naming.api_module(bc_module)
      port_api = Naming.port_api_module(bc_module)
      bc_registry = Module.concat(bc_module, AdapterRegistry)
      tenant? = !!igniter.args.options[:tenant]

      igniter
      |> create_port_api(port_api)
      |> create_api(api, port_api, bc_module, context_atom)
      |> create_bc_registry(bc_registry, api)
      |> ensure_placeholder_dirs(bc_module)
      |> register_child(root_registry, bc_registry)
      |> Igniter.add_notice("""
      Bounded context #{inspect(bc_module)} created.

      Add an aggregate:
        mix dobro.gen.aggregate #{inspect(bc_module)}.Thing --fields name:string#{if tenant?, do: " --tenant", else: ""}
      """)
    end

    defp create_port_api(igniter, port_api) do
      Igniter.Project.Module.create_module(igniter, port_api, """
      @moduledoc false
      use Dobro.App.Api.Port
      """)
    end

    defp create_api(igniter, api, port_api, bc_module, context_atom) do
      Igniter.Project.Module.create_module(igniter, api, """
      @moduledoc \"\"\"
      Public API for #{inspect(bc_module)}.
      \"\"\"
      use Dobro.App.Api,
        port: #{inspect(port_api)},
        context: {#{inspect(bc_module)}, #{inspect(context_atom)}},
        surfaces: [:graphql]

      # route :get_thing,
      #   query: #{inspect(bc_module)}.App.ThingQueries.GetThing,
      #   to: #{inspect(bc_module)}.App.ThingQueries.Handler,
      #   policy: #{inspect(Naming.policy_read(context_atom))}
      """)
    end

    defp create_bc_registry(igniter, bc_registry, api) do
      Igniter.Project.Module.create_module(igniter, bc_registry, """
      @moduledoc false
      use Dobro.Spec.AdapterRegistry

      register #{inspect(api)}
      """)
    end

    defp ensure_placeholder_dirs(igniter, bc_module) do
      base_path =
        igniter
        |> Igniter.Project.Module.proper_location(bc_module)
        |> Path.dirname()

      Enum.reduce(["domain", "app", "infra/data", "ports"], igniter, fn dir, igniter ->
        keep = Path.join([base_path, dir, ".gitkeep"])
        Igniter.create_new_file(igniter, keep, "")
      end)
    end

    defp register_child(igniter, root_registry, bc_registry) do
      case Igniter.Project.Module.module_exists(igniter, root_registry) do
        {true, igniter} ->
          Igniter.Project.Module.find_and_update_module!(igniter, root_registry, fn zipper ->
            # zipper is already inside the module's do block
            {:ok,
             Igniter.Code.Common.add_code(zipper, "register_child #{inspect(bc_registry)}")}
          end)

        {false, igniter} ->
          Igniter.add_warning(
            igniter,
            "Root registry #{inspect(root_registry)} not found. Run `mix dobro.install` first, then add `register_child #{inspect(bc_registry)}`."
          )
      end
    end
  end
else
  defmodule Mix.Tasks.Dobro.Gen.Bc do
    @moduledoc "Generates a Dobro bounded context skeleton"
    @shortdoc @moduledoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("dobro.gen.bc requires igniter. See https://hexdocs.pm/igniter")
      exit({:shutdown, 1})
    end
  end
end
