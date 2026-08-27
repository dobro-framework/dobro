if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Dobro.Gen.Aggregate do
    @shortdoc "Generates a Dobro aggregate vertical slice inside a bounded context"

    @moduledoc """
    #{@shortdoc}

        mix dobro.gen.aggregate MyApp.Catalog.Products.Product --fields name:string,sku:string

    Generates domain aggregate + events, commands/queries, ports, Ecto schema/repos,
    API routes, and registers adapters on the BC adapter registry.

    ## Options

    * `--fields` — comma-separated `name:type` pairs (default `name:string`)
    * `--tenant` — schema-per-tenant repos (`tenant_strategy: :schema`)
    * `--bc` — create the bounded context first if missing (runs `dobro.gen.bc`)
    """

    use Igniter.Mix.Task

    alias Dobro.Igniter.Naming

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :dobro,
        schema: [
          fields: :string,
          tenant: :boolean,
          bc: :boolean
        ],
        defaults: [
          fields: "name:string",
          tenant: false,
          bc: true
        ],
        positional: [:aggregate],
        composes: ["dobro.gen.bc"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      aggregate_module =
        igniter.args.positional[:aggregate]
        |> List.wrap()
        |> List.first()
        |> to_string()
        |> Igniter.Project.Module.parse()

      meta = Naming.split_aggregate(aggregate_module)
      fields = Naming.parse_fields(igniter.args.options[:fields])
      tenant? = !!igniter.args.options[:tenant]
      create_bc? = igniter.args.options[:bc] != false

      igniter
      |> maybe_gen_bc(meta.bc_module, create_bc?, tenant?)
      |> create_domain(meta, fields)
      |> create_events(meta, fields)
      |> create_commands(meta, fields, tenant?)
      |> create_queries(meta, fields, tenant?)
      |> create_ports(meta)
      |> create_schema(meta, fields)
      |> create_write_repo(meta, tenant?)
      |> create_read_repo(meta, fields, tenant?)
      |> patch_api(meta, tenant?)
      |> patch_bc_registry(meta)
      |> Igniter.add_notice("""
      Aggregate #{inspect(meta.aggregate_module)} generated under #{inspect(meta.bc_module)}.

      Add a migration for table #{inspect(meta.table)}, then implement any custom specs.
      """)
    end

    defp maybe_gen_bc(igniter, bc_module, true, tenant?) do
      api = Naming.api_module(bc_module)

      case Igniter.Project.Module.module_exists(igniter, api) do
        {true, igniter} ->
          igniter

        {false, igniter} ->
          args = [inspect(bc_module)] ++ if(tenant?, do: ["--tenant"], else: [])
          Igniter.compose_task(igniter, "dobro.gen.bc", args)
      end
    end

    defp maybe_gen_bc(igniter, _bc_module, false, _tenant?), do: igniter

    defp create_domain(igniter, meta, fields) do
      field_lines =
        Enum.map_join(fields, "\n", fn {name, type} ->
          "    field :#{name}, #{inspect(type)}, required: true"
        end)

      create_fields =
        Enum.map_join(fields, "\n", fn {name, type} ->
          "    field :#{name}, #{inspect(type)}, required: true"
        end)

      Igniter.Project.Module.create_module(igniter, meta.aggregate_module, """
      @moduledoc \"\"\"
      #{meta.aggregate_name} aggregate
      \"\"\"
      use Dobro.Domain.Aggregate
      alias #{inspect(meta.bc_module)}.Domain.Events

      state do
        field :id, :id, immutable: true
      #{field_lines}
      end

      defcontract Create do
      #{create_fields}
      end

      defcontract Update do
      #{create_fields}
      end

      defcontract Delete

      def create(%Create{} = input) do
        pipeline(input)
        |> add_event(Events.#{meta.aggregate_name}Created)
        |> apply_changes()
      end

      def update(%__MODULE__{} = aggregate, %Update{} = input) do
        aggregate
        |> pipeline(input)
        |> add_event(Events.#{meta.aggregate_name}Updated)
        |> apply_changes()
      end

      def delete(%__MODULE__{} = aggregate, %Delete{} = input) do
        aggregate
        |> pipeline(input)
        |> add_event(Events.#{meta.aggregate_name}Deleted, &with_deleted_at/2)
        |> apply_changes()
      end

      defapply Events.#{meta.aggregate_name}Created
      defapply Events.#{meta.aggregate_name}Updated
      defapply Events.#{meta.aggregate_name}Deleted

      defp with_deleted_at(event, _aggregate) do
        %{event | payload: Map.put(event.payload, :deleted_at, DateTime.utc_now())}
      end
      """)
    end

    defp create_events(igniter, meta, fields) do
      events_mod = Module.concat([meta.bc_module, Domain, Events])

      payload_fields =
        Enum.map_join(fields, "\n", fn {name, type} ->
          "      field :#{name}, #{inspect(type)}"
        end)

      content = """
      @moduledoc \"\"\"
      Domain events for #{inspect(meta.bc_module)}
      \"\"\"
      use Dobro.Domain.EventDefinition
      use Dobro.Contract

      defevent #{meta.aggregate_name}Created do
        payload do
      #{payload_fields}
        end
      end

      defevent #{meta.aggregate_name}Updated do
        payload do
          field :id, :id
      #{payload_fields}
        end
      end

      defevent #{meta.aggregate_name}Deleted do
        payload do
          field :id, :id
          field :deleted_at, :datetime
        end
      end
      """

      case Igniter.Project.Module.module_exists(igniter, events_mod) do
        {true, igniter} ->
          Igniter.add_notice(
            igniter,
            "#{inspect(events_mod)} already exists — append #{meta.aggregate_name}Created/Updated/Deleted events manually if missing."
          )

        {false, igniter} ->
          Igniter.Project.Module.create_module(igniter, events_mod, content)
      end
    end

    defp create_commands(igniter, meta, fields, tenant?) do
      commands = Module.concat([meta.bc_module, App, :"#{meta.aggregate_name}Commands"])
      scope = if tenant?, do: "    scope :tenant, from: :payload", else: ""

      input_fields =
        Enum.map_join(fields, "\n", fn {name, type} ->
          "    field :#{name}, #{inspect(type)}, required: true"
        end)

      result_fields =
        Enum.map_join(fields, "\n", fn {name, type} ->
          "    field :#{name}, #{inspect(type)}"
        end)

      Igniter.Project.Module.create_module(igniter, commands, """
      @moduledoc false
      use Dobro.App.CommandDefinition
      alias Dobro.App.Types
      alias #{inspect(meta.aggregate_module)}

      defcontract Create#{meta.aggregate_name}Result do
        field :id, :id
      #{result_fields}
      end

      defcontract Create#{meta.aggregate_name}Input do
      #{input_fields}
      end

      defcontract Update#{meta.aggregate_name}Input do
      #{input_fields}
      end

      command Create#{meta.aggregate_name} do
        description "Create a #{meta.singular}."
      #{scope}
        payload Create#{meta.aggregate_name}Input
        result Create#{meta.aggregate_name}Result
      end

      command Update#{meta.aggregate_name} do
        description "Update a #{meta.singular}."
      #{scope}
        identity do
          field :id, :id
        end
        payload Update#{meta.aggregate_name}Input
        result Types.Identified
      end

      command Delete#{meta.aggregate_name} do
        description "Delete a #{meta.singular}."
      #{scope}
        identity do
          field :id, :id
        end
        result Types.Deleted
      end

      command_handler Handler, aggregate: #{meta.aggregate_name} do
        handle Create#{meta.aggregate_name}, :create, contract: #{meta.aggregate_name}.Create
        handle Update#{meta.aggregate_name}, :update, contract: #{meta.aggregate_name}.Update
        handle Delete#{meta.aggregate_name}, :delete, contract: #{meta.aggregate_name}.Delete
      end
      """)
    end

    defp create_queries(igniter, meta, fields, tenant?) do
      queries = Module.concat([meta.bc_module, App, :"#{meta.aggregate_name}Queries"])
      port = Module.concat([meta.bc_module, Ports, :"#{meta.aggregate_name}ReadRepo"])
      scope = if tenant?, do: "    scope :tenant, from: :payload", else: ""

      result_fields =
        Enum.map_join(fields, "\n", fn {name, type} ->
          "    field :#{name}, #{inspect(type)}"
        end)

      list_item_fields =
        Enum.map_join(fields, "\n", fn {name, type} ->
          "    field :#{name}, #{inspect(type)}"
        end)

      tenant_payload =
        if tenant? do
          "      field :tenant_id, :id, required: true"
        else
          ""
        end

      Igniter.Project.Module.create_module(igniter, queries, """
      @moduledoc false
      use Dobro.App.QueryDefinition
      alias Dobro.App.Types.{Pagination, Query}
      alias #{inspect(port)}

      defcontract #{meta.aggregate_name} do
        field :id, :id
      #{result_fields}
      end

      defcontract #{meta.aggregate_name}ListItem do
        field :id, :id
      #{list_item_fields}
      end

      defcontract #{meta.aggregate_name}List do
        field :meta, Pagination
        field :items, list_of(#{meta.aggregate_name}ListItem)
      end

      query Get#{meta.aggregate_name} do
        description "Fetch a #{meta.singular} by id."
      #{scope}
        payload do
      #{tenant_payload}
          field :id, :id, required: true
        end
        result #{meta.aggregate_name}
      end

      query List#{meta.aggregate_name}s do
        description "List #{meta.table}."
      #{scope}
        payload do
      #{tenant_payload}
          field :query, Query
        end
        result #{meta.aggregate_name}List
      end

      query_handler Handler, repo: #{meta.aggregate_name}ReadRepo do
        handle Get#{meta.aggregate_name}
        handle List#{meta.aggregate_name}s
      end
      """)
    end

    defp create_ports(igniter, meta) do
      read_port = Module.concat([meta.bc_module, Ports, :"#{meta.aggregate_name}ReadRepo"])
      write_port = Module.concat([meta.bc_module, Ports, :"#{meta.aggregate_name}WriteRepo"])

      igniter
      |> Igniter.Project.Module.create_module(read_port, """
      @moduledoc false
      use Dobro.Infra.Data.ReadRepo.PortDefinition
      """)
      |> Igniter.Project.Module.create_module(write_port, """
      @moduledoc false
      use Dobro.Infra.Data.WriteRepo.PortDefinition
      """)
    end

    defp create_schema(igniter, meta, fields) do
      schema = Module.concat([meta.bc_module, Infra, Data, :"#{meta.aggregate_name}Schema"])

      ecto_fields =
        Enum.map_join(fields, "\n", fn {name, type} ->
          ecto_type = ecto_type(type)
          "    field :#{name}, #{inspect(ecto_type)}"
        end)

      cast_fields =
        fields
        |> Enum.map(fn {name, _} -> ":#{name}" end)
        |> Enum.join(", ")

      required =
        fields
        |> Enum.map(fn {name, _} -> ":#{name}" end)
        |> Enum.join(", ")

      Igniter.Project.Module.create_module(igniter, schema, """
      @moduledoc false
      use TypedEctoSchema
      import Ecto.Changeset

      @primary_key {:id, :id, autogenerate: true}
      @timestamps_opts [inserted_at: :created_at]
      typed_schema #{inspect(meta.table)} do
      #{ecto_fields}
        field :version, :integer, default: 1
        timestamps()
      end

      def changeset(struct, attrs) do
        struct
        |> cast(attrs, [:version, #{cast_fields}])
        |> validate_required([#{required}])
      end
      """)
    end

    defp create_write_repo(igniter, meta, tenant?) do
      write_repo = Module.concat([meta.bc_module, Infra, Data, :"#{meta.aggregate_name}WriteRepo"])
      schema = Module.concat([meta.bc_module, Infra, Data, :"#{meta.aggregate_name}Schema"])
      tenant_opts =
        if tenant?, do: ",\n        tenant_strategy: :schema", else: ""

      Igniter.Project.Module.create_module(igniter, write_repo, """
      @moduledoc false
      alias #{inspect(meta.aggregate_module)}
      alias #{inspect(schema)}

      use Dobro.Infra.Data.WriteRepo,
        aggregate: #{meta.aggregate_name},
        schema: #{meta.aggregate_name}Schema#{tenant_opts}
      """)
    end

    defp create_read_repo(igniter, meta, fields, tenant?) do
      read_repo = Module.concat([meta.bc_module, Infra, Data, :"#{meta.aggregate_name}ReadRepo"])
      port = Module.concat([meta.bc_module, Ports, :"#{meta.aggregate_name}ReadRepo"])
      schema = Module.concat([meta.bc_module, Infra, Data, :"#{meta.aggregate_name}Schema"])

      tenant_opts =
        if tenant? do
          ",\n        tenant_strategy: :schema,\n        scopes: [:tenant]"
        else
          ",\n        scopes: []"
        end

      field_list =
        fields
        |> Enum.map(fn {name, _} -> ":#{name}" end)
        |> Enum.join(", ")

      Igniter.Project.Module.create_module(igniter, read_repo, """
      @moduledoc false
      alias #{inspect(schema)}

      use Dobro.Infra.Data.ReadRepo,
        port: #{inspect(port)},
        schema: #{meta.aggregate_name}Schema#{tenant_opts}

      defquery Get#{meta.aggregate_name}, type: :one do
        fields [:id, #{field_list}]
      end

      defquery List#{meta.aggregate_name}s, type: :list do
        fields [:id, #{field_list}]
      end
      """)
    end

    defp patch_api(igniter, meta, _tenant?) do
      api = Naming.api_module(meta.bc_module)
      commands = Module.concat([meta.bc_module, App, :"#{meta.aggregate_name}Commands"])
      queries = Module.concat([meta.bc_module, App, :"#{meta.aggregate_name}Queries"])
      read = Naming.policy_read(meta.context_atom)
      manage = Naming.policy_manage(meta.context_atom)

      routes = """
      alias #{inspect(commands)}
      alias #{inspect(queries)}

      @read #{inspect(read)}
      @manage #{inspect(manage)}

      route :get_#{meta.singular},
        query: #{meta.aggregate_name}Queries.Get#{meta.aggregate_name},
        to: #{meta.aggregate_name}Queries.Handler,
        policy: @read

      route :list_#{meta.singular}s,
        query: #{meta.aggregate_name}Queries.List#{meta.aggregate_name}s,
        to: #{meta.aggregate_name}Queries.Handler,
        policy: @read

      route :create_#{meta.singular},
        command: #{meta.aggregate_name}Commands.Create#{meta.aggregate_name},
        to: #{meta.aggregate_name}Commands.Handler,
        policy: @manage

      route :update_#{meta.singular},
        command: #{meta.aggregate_name}Commands.Update#{meta.aggregate_name},
        to: #{meta.aggregate_name}Commands.Handler,
        policy: @manage,
        returning: :get_#{meta.singular}

      route :delete_#{meta.singular},
        command: #{meta.aggregate_name}Commands.Delete#{meta.aggregate_name},
        to: #{meta.aggregate_name}Commands.Handler,
        policy: @manage
      """

      case Igniter.Project.Module.module_exists(igniter, api) do
        {true, igniter} ->
          Igniter.Project.Module.find_and_update_module!(igniter, api, fn zipper ->
            {:ok, Igniter.Code.Common.add_code(zipper, routes)}
          end)

        {false, igniter} ->
          Igniter.add_warning(igniter, "API module #{inspect(api)} missing; skip route patch.")
      end
    end

    defp patch_bc_registry(igniter, meta) do
      registry = Module.concat(meta.bc_module, AdapterRegistry)
      read_repo = Module.concat([meta.bc_module, Infra, Data, :"#{meta.aggregate_name}ReadRepo"])
      write_repo = Module.concat([meta.bc_module, Infra, Data, :"#{meta.aggregate_name}WriteRepo"])

      regs = """
      register #{inspect(read_repo)}
      register #{inspect(write_repo)}
      """

      case Igniter.Project.Module.module_exists(igniter, registry) do
        {true, igniter} ->
          Igniter.Project.Module.find_and_update_module!(igniter, registry, fn zipper ->
            {:ok, Igniter.Code.Common.add_code(zipper, regs)}
          end)

        {false, igniter} ->
          Igniter.add_warning(igniter, "BC registry #{inspect(registry)} missing.")
      end
    end

    defp ecto_type(:string), do: :string
    defp ecto_type(:integer), do: :integer
    defp ecto_type(:boolean), do: :boolean
    defp ecto_type(:id), do: :id
    defp ecto_type(:float), do: :float
    defp ecto_type(:map), do: :map
    defp ecto_type(:utc_datetime), do: :utc_datetime
    defp ecto_type(other), do: other
  end
else
  defmodule Mix.Tasks.Dobro.Gen.Aggregate do
    @moduledoc "Generates a Dobro aggregate vertical slice inside a bounded context"
    @shortdoc @moduledoc
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("dobro.gen.aggregate requires igniter. See https://hexdocs.pm/igniter")
      exit({:shutdown, 1})
    end
  end
end
