if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Dobro.Install do
    @shortdoc "Installs Dobro into a project. Use via `mix igniter.install dobro`"

    @moduledoc """
    #{@shortdoc}

    ## Options

    * `--tenant` — wire schema-per-tenant support (adds a `TenantResolver` stub and config)
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :dobro,
        schema: [
          tenant: :boolean
        ],
        defaults: [
          tenant: false
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = Igniter.Project.Application.app_name(igniter)
      base = Igniter.Project.Module.module_name_prefix(igniter)
      registry = Module.concat(base, AdapterRegistry)
      pubsub = Module.concat(base, PubSub)
      tenant? = !!igniter.args.options[:tenant]

      igniter
      |> create_adapter_registry(registry)
      |> maybe_create_tenant_resolver(base, tenant?)
      |> configure_dobro(app_name, base, registry, pubsub, tenant?)
      |> add_runtime_children(pubsub)
      |> Igniter.add_notice("""
      Dobro installed for #{inspect(app_name)}.

      Next:
        mix dobro.gen.bc #{inspect(base)}.Catalog.Products
        mix dobro.gen.aggregate #{inspect(base)}.Catalog.Products.Product --fields name:string

      GraphQL (optional): mix igniter.install dobro_graphql
      AI (optional):      mix igniter.install dobro_ai
      """)
    end

    defp create_adapter_registry(igniter, registry) do
      Igniter.Project.Module.create_module(igniter, registry, """
      @moduledoc \"\"\"
      Root adapter registry.

      Register bounded-context registries with `register_child/1`.
      \"\"\"
      use Dobro.Spec.AdapterRegistry
      """)
    end

    defp maybe_create_tenant_resolver(igniter, _base, false), do: igniter

    defp maybe_create_tenant_resolver(igniter, base, true) do
      resolver = Module.concat([base, Dobro, TenantResolver])

      Igniter.Project.Module.create_module(igniter, resolver, """
      @moduledoc \"\"\"
      Resolves tenant identifiers to Postgres schema prefixes.

      Replace stubbed id→identifier lookup with your tenant directory as needed.
      \"\"\"
      @behaviour Dobro.Tenant.Resolver

      alias Dobro.App.Auth.TenantContext

      @impl Dobro.Tenant.Resolver
      def normalize(%TenantContext{id: id, identifier: identifier} = tenant)
          when not is_nil(id) and is_binary(identifier) and identifier != "" do
        {:ok, tenant}
      end

      def normalize(%TenantContext{identifier: identifier} = tenant)
          when is_binary(identifier) and identifier != "" do
        {:ok, tenant}
      end

      def normalize(%TenantContext{id: id}) when not is_nil(id) do
        {:ok, TenantContext.new(id: id, identifier: "tenant_\#{id}")}
      end

      def normalize(_), do: {:error, :missing_tenant}

      @impl Dobro.Tenant.Resolver
      def schema_prefix_for(%TenantContext{identifier: identifier})
          when is_binary(identifier) and identifier != "" do
        {:ok, identifier}
      end

      def schema_prefix_for(_), do: {:error, :missing_tenant}

      @impl Dobro.Tenant.Resolver
      def schema_prefix_for!(tenant) do
        case schema_prefix_for(tenant) do
          {:ok, prefix} -> prefix
          {:error, reason} -> raise "tenant schema prefix failed: \#{inspect(reason)}"
        end
      end
      """)
    end

    defp configure_dobro(igniter, app_name, base, registry, pubsub, tenant?) do
      {repo, igniter} = find_repo(igniter, base)

      igniter
      |> Igniter.Project.Config.configure("config.exs", :dobro_spec, [:otp_app], app_name)
      |> Igniter.Project.Config.configure(
        "config.exs",
        :dobro_spec,
        [:adapter_registry],
        registry
      )
      |> Igniter.Project.Config.configure("config.exs", :dobro_runtime, [:pubsub], pubsub)
      |> Igniter.Project.Config.configure(
        "config.exs",
        :dobro_runtime,
        [:outbox_relay],
        [
          enabled: false,
          batch_size: 100,
          poll_interval_ms: 1_000,
          claim_timeout_ms: 300_000,
          purge_after_ms: nil,
          purge_interval_ms: 60_000
        ]
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        :dobro_cqrs,
        [:execution_strategy],
        :actor_when_identified
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        :dobro_cqrs,
        [:persistence_strategy],
        :stateful
      )
      |> Igniter.Project.Config.configure(
        "config.exs",
        :dobro_cqrs,
        [:event_delivery_strategy],
        :pubsub
      )
      |> then(fn igniter ->
        if repo do
          Igniter.Project.Config.configure(igniter, "config.exs", :dobro_ecto, [:repo], repo)
        else
          Igniter.add_notice(
            igniter,
            "No Ecto.Repo found. After adding one, set `config :dobro_ecto, repo: MyApp.Repo`."
          )
        end
      end)
      |> then(fn igniter ->
        if tenant? do
          resolver = Module.concat([base, Dobro, TenantResolver])

          Igniter.Project.Config.configure(
            igniter,
            "config.exs",
            :dobro_ecto,
            [:tenant_resolver],
            resolver
          )
        else
          igniter
        end
      end)
    end

    defp find_repo(igniter, base) do
      candidate = Module.concat(base, Repo)

      case Igniter.Project.Module.module_exists(igniter, candidate) do
        {true, igniter} -> {candidate, igniter}
        {false, igniter} -> {nil, igniter}
      end
    end

    defp add_runtime_children(igniter, pubsub) do
      igniter
      |> Igniter.Project.Application.add_new_child({Phoenix.PubSub, name: pubsub})
      |> Igniter.Project.Application.add_new_child(
        {Registry, keys: :unique, name: Dobro.Runtime.Registry}
      )
      # Also start Dobro.Runtime.ActorLock.child_specs() when using ActorLock.Postgres
      |> Igniter.Project.Application.add_new_child(
        {Dobro.Runtime.AggregateSupervisor, name: Dobro.Runtime.AggregateSupervisor}
      )
      |> Igniter.Project.Application.add_new_child(
        {Dobro.Runtime.EventHandlerSupervisor, name: Dobro.Runtime.EventHandlerSupervisor}
      )
    end
  end
else
  defmodule Mix.Tasks.Dobro.Install do
    @moduledoc "Installs Dobro into a project. Use via `mix igniter.install dobro`"
    @shortdoc @moduledoc

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'dobro.install' requires igniter.

      Add {:igniter, "~> 0.6"} to your deps (or run via mix igniter.install dobro) and try again.
      See https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
