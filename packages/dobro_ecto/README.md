# Dobro Ecto

Ecto-backed read and write repositories, the **`defquery` infrastructure DSL**, projection support, and aggregate persistence helpers.

This package is the **infrastructure layer** for data access. It implements how reads and writes are executed in PostgreSQL (or any Ecto-supported database). Application use cases — commands and queries exposed to callers — are defined in [dobro_cqrs](https://hexdocs.pm/dobro_cqrs).

## Requirements

- Elixir ~> 1.14
- Ecto ~> 3.10
- [dobro_spec](https://hexdocs.pm/dobro_spec), [dobro_schema](https://hexdocs.pm/dobro_schema), [dobro_domain](https://hexdocs.pm/dobro_domain) ~> 0.1

## Installation

```elixir
def deps do
  [{:dobro_ecto, "~> 0.1.0"}]
end
```

## Configuration

```elixir
config :dobro_ecto,
  repo: MyApp.Repo,
  tenant_resolver: MyApp.TenantResolver   # required for :schema tenant strategy
```

| Key | Description |
|-----|-------------|
| `:repo` | Ecto repo module used for all read/write operations |
| `:tenant_resolver` | Module implementing `Dobro.Tenant.Resolver` for schema-prefix multi-tenancy |

---

## Application vs infrastructure queries

Dobro separates **what** can be queried from **how** it is queried.

| Layer | Package | Defines | Example |
|-------|---------|---------|---------|
| **Application query** | `dobro_cqrs` | Use-case input: scope, payload fields | `CategoryQueries.ListCategories` |
| **Infrastructure query** | `dobro_ecto` (this package) | Ecto SQL via `defquery` | `CategoryReadRepo.list_categories/1` |

Application query handlers call repo functions by name:

```elixir
# dobro_cqrs
handle ListCategories, :list_categories

# dobro_ecto — defaults to list_categories/1 from the module name
defquery ListCategories, type: :list do
  ...
end
```

The handler passes the application query payload as a plain map. For list queries, pagination and filters arrive in `args[:query]` as a `Dobro.App.Types.Query` struct (converted to a map by the handler).

See [dobro_cqrs](https://hexdocs.pm/dobro_cqrs) for application query definitions.

---

## Persistence model

Dobro separates **event-driven state transitions** (domain layer) from **storage strategy** (this package):

| Strategy | How it works | Status |
|----------|--------------|--------|
| **Stateful persistence** | Write repositories persist aggregate snapshots and events to relational tables | Available |
| **Event-sourced persistence** | Events appended to an event store; state rebuilt by replay | Available |

### Write path

```
Command handler (dobro_cqrs)
  → aggregate function (events + state in memory)
  → Command.Commit
  → PersistenceStrategy (Stateful or EventSourced)
      → WriteRepo.Persist (stateful) or EventStore.append (event-sourced)
      → EventEnrichment (stateful path)
  → Event delivery strategy (none, pubsub, or outbox)
```

---

## Read repositories

Read repos are port adapters that expose query functions to the application layer.

```elixir
defmodule MyApp.Archive.Infra.CategoryReadRepo do
  use Dobro.Infra.Data.ReadRepo,
    port: MyApp.Archive.Ports.CategoryReadRepo,
    schema: MyApp.Archive.CategorySchema,
    scopes: [:global]

  # Infrastructure queries — see below
end
```

Register the repo in your adapter registry. Application query handlers resolve it through the port:

```elixir
CategoryReadRepo.adapter().list_categories(%{tenant_id: 1, query: query_map})
```

### Read repo options

| Option | Purpose |
|--------|---------|
| `:port` | Port module (required) |
| `:schema` | Root Ecto schema module |
| `:scopes` | Allowed scope modes — `[:global]`, `[:tenant]`, or both |
| `:tenant_strategy` | `:tenant_id`, `:schema`, or `nil` |
| `:query_defaults` | Default options for all queries on this repo, e.g. `[include_global: false]` — overridden per `defquery` |
| `:context_mode` | `:tenant` (requires context on every call) or `:none` |

Per-query `defquery` options take precedence over repo defaults. Example for a strictly tenant-scoped repo:

```elixir
use Dobro.Infra.Data.ReadRepo,
  port: MyApp.Ports.EntryReadRepo,
  schema: EntrySchema,
  tenant_strategy: :tenant_id,
  query_defaults: [include_global: false]

defquery ListEntries, type: :list do
  fields [:id, :tenant_id, :name, :reference, :date_time]
  # inherits include_global: false
end
```

---

## Infrastructure queries (`defquery`)

`defquery` is declared **inside a read repo module**. It generates a repo function (defaulting from the query module name; override with `:as`) that executes an Ecto query with optional filtering, sorting, pagination, joins, and preloads.

This is **not** the same as `query` in `Dobro.App.QueryDefinition` — that macro defines application-layer use cases in `dobro_cqrs`.

### List query

```elixir
defquery ListCategories, type: :list do
  fields [:id, :name, :identifier, :tenant_id]

  join :tenant, type: :left do
    field :tenant_name, :name
  end

  query fn args, _context ->
    from(c in schema(), as: :category)
    |> maybe_apply_tenant(args[:tenant_id], include_global: true)
  end
end
```

Generates `list_categories/1` (or `/2` with context). The handler calls this function with the application query payload as `args`. List filtering and pagination are read from `args[:query]`.

`:list` and `:one` queries must declare projected fields with `field/1`, `fields/1`, and/or join `field/1`. Schema columns are **not** inferred.

### Single-record query

```elixir
defquery GetCategory, type: :one do
  fields [:id, :name, :identifier, :tenant_id]
  preload :tenant, MyApp.Tenants.TenantSchema, fields: [:id, :name]
end
```

Looks up by identity fields on the payload (for example `id`). Returns `{:ok, record}` or `{:error, :category_not_found}`.

`:one` queries support `preload`, `join`, and custom `query` blocks. ### Preloads

Association preloads for `:one` queries:

```elixir
defquery GetCategory, type: :one do
  fields [:id, :name, :identifier, :tenant_id]
  preload :tenant, TenantShadowSchema, fields: [:id, :name]
end
```

Nested preloads:

```elixir
defquery GetEntry, type: :one do
  fields [:id, :tenant_id, :data, :name, :import_id]

  preload :import, ImportSchema do
    preload :mapping, MappingSchema
  end
end
```

Use **preload** when the API exposes nested associations. Use **join** only for flat fields on list items (for example `tenant_name`).

When a derived `expr` field references a join binding (for example `tenant: t`) but the list contract does not expose a flat join field, keep the join in the custom `query` block — the join DSL only auto-applies joins required by declared join fields.

When a `Dobro.App.Selection` is present (from GraphQL), joins and root columns are projected to match the client request; preloads are skipped when the association is not selected. Without selection, the full schema struct is loaded.

### Exists query

```elixir
defquery CategoryExists, type: :exists do
  query fn args, _context ->
    from(c in schema(), as: :category)
    |> where([c], c.identifier == ^args[:identifier])
  end
end
```

Returns a boolean. When the default “any row in the repo schema” check is enough
(tenant scoping comes from the read-repo strategy/context), omit the `do` block:

```elixir
defquery OfficeExistsForTenant, type: :exists
```

### Query types

| Type | Repo function behaviour |
|------|-------------------------|
| `:list` | Paginated collection with filter/sort from `args[:query]` |
| `:one` | Single record by identity fields |
| `:exists` | Boolean existence check |

### `defquery` options

| Option | Purpose |
|--------|---------|
| `:type` | `:list`, `:one`, or `:exists` (required) |
| `:as` | Repo function name. Defaults to `Macro.underscore` of the module (`ListCategories` → `:list_categories`); `:exists` appends `?`. Pass an atom to override, or `false`/`nil` to skip defining a function. |
| `:binding` | Override root Ecto binding atom |
| `:schema` | Override schema when not set on `use ReadRepo` |
| `:id_field` | For `:one`, args key used for lookup (default `:id`; e.g. `:username`) |
| `:include_global` | For `:one` and `:list` with tenant-id strategy, forwarded to the tenant filter |

### Joins

Join related tables through Ecto associations — no manual `on:` clauses:

```elixir
defquery ListMappings, type: :list do
  fields [:id, :tenant_id, :template_id, :name]

  join :tenant, type: :inner do
    field :tenant_name, :name
  end

  join :template, type: :inner do
    field :template_name, :name, filterable: false
  end

  filterable [:name, :tenant_name]
  sortable [:name, :tenant_name, :template_name]

  query fn _args, _context ->
    from(m in schema(), as: :mapping)
  end
end
```

Use `through:` to chain joins via an earlier binding:

```elixir
join :region, through: :tenant do
  field :region_name, :name
end
```

### Derived fields (`expr:`)

Project, filter, and sort on computed SQL expressions — for example keys inside a JSON/embed column:

```elixir
defquery ListOffices, type: :list do
  fields [:id, :name, :office_group_id]

  field :abbreviation,
    expr: dynamic([office: o], fragment("?->>'abbreviation'", o.json_attributes))

  filterable [:name, :abbreviation]
  sortable [:name, :abbreviation]

  query fn _args, context ->
    [prefix: prefix] = Dobro.Infra.SchemaPrefix.repo_opts!(context)
    from(o in schema(), prefix: ^prefix)
  end
end
```

The root binding in `dynamic([...])` must match the query’s `as:` (default: inferred from the schema module name, e.g. `OfficeSchema` → `:office`).

Compiled `expr` fields are stored as `{repo_module, fun}` and invoked at query time (Ecto `DynamicExpr` values cannot be Macro.escape’d into `__spec__/0`). Hand-built specs in tests may pass `{:expr, dynamic(...)}` directly.

### Filterable and sortable fields

Declared fields are **filterable and sortable by default**. You can set opts on each field:

```elixir
field :id, filterable: true, sortable: true   # explicit (same as default)
field :name                                   # both true by default
field :value, filterable: false, sortable: false
field :tenant_name, :name, filterable: true, sortable: false
```

Or use the `fields/1` shorthand for plain root columns (all queryable by default):

```elixir
fields [:id, :name, :identifier, :tenant_id]
```

Or replace the allow-lists entirely with top-level declarations (useful when many columns are projected but only a few are queryable):

```elixir
fields [:id, :name, :identifier, :tenant_id]
filterable [:name, :identifier]
sortable [:id, :name, :tenant_name]
```

Join and `expr` fields must be declared with `field` before they can appear in these lists.

Filters arrive from the application layer as `args[:query].filters` — a list of `%{field, op, value}` maps defined by `Dobro.App.Types.Filter` in `dobro_cqrs`.

### Field selection

When GraphQL (or another transport) attaches a `Dobro.App.Selection` to the read context, list and `:one` queries limit selected columns, joins, and association preloads to what the client requested. Pass selection via `ReadRepo.Context`:

```elixir
ReadRepo.Context.new(tenant: tenant, selection: selection)
```

---

## Custom repo functions

Not every read requires `defquery`. Implement plain functions for simple operations:

```elixir
defmodule MyApp.Offices.Infra.OfficeReadRepo do
  use Dobro.Infra.Data.ReadRepo,
    port: MyApp.Offices.Ports.OfficeReadRepo,
    schema: MyApp.Offices.OfficeSchema,
    tenant_strategy: :schema,
    scopes: [:tenant]

  def office_exists_for_tenant?(_input, %Context{} = context) do
    schema() |> exists?(context: context)
  end
end
```

Wire custom functions from application query handlers the same way:

```elixir
handle OfficeExistsForTenant, :office_exists_for_tenant?
```

---

## Write repositories

Write repos map domain aggregates to Ecto schemas and are registered as write port adapters:

```elixir
defmodule MyApp.Archive.Infra.CategoryWriteRepo do
  use Dobro.Infra.Data.WriteRepo,
    aggregate: MyApp.Archive.Domain.Category,
    schema: MyApp.Archive.CategorySchema,
    mapper: MyApp.Archive.CategoryMapper,
    tenant_strategy: nil,
    on_delete: :hard_delete
end
```

Command handlers select the write repo by aggregate module and operation (`:insert`, `:update`, `:delete`).

### Delete strategies

| Strategy | Config | Behaviour |
|----------|--------|-----------|
| Hard delete | `:hard_delete` (default) | Removes the row |
| Soft delete (datetime) | `{SoftDelete.DateTime, deleted_at: :deleted_at}` | Sets timestamp |
| Soft delete (boolean) | `{SoftDelete.Boolean, field: :deleted}` | Sets flag |
| Soft delete (status) | `{SoftDelete.Status, field: :status, value: "deleted"}` | Sets status |
| Event only | `:event_only` | No row deletion; domain delete event only |

### Custom load functions

```elixir
def get_default_office_by_tenant(context) do
  case first(context) do
    {:ok, unit_of_work} -> {:ok, unit_of_work}
    {:error, _} -> {:ok, nil}
  end
end
```

Used by aggregate actors and command handlers for identity resolution.

---

## Multi-tenancy

```elixir
defmodule MyApp.TenantResolver do
  @behaviour Dobro.Tenant.Resolver

  @impl true
  def schema_prefix_for(%{identifier: id}), do: {:ok, to_string(id)}

  @impl true
  def schema_prefix_for!(tenant) do
    {:ok, prefix} = schema_prefix_for(tenant)
    prefix
  end
end
```

| Strategy | Config | Behaviour |
|----------|--------|-----------|
| None | `tenant_strategy: nil` | No tenant filtering |
| Column | `tenant_strategy: :tenant_id` | Filter by `tenant_id` column |
| Schema prefix | `tenant_strategy: :schema` | Postgres schema per tenant |

---

## Projections

Projectors maintain read models from domain events:

```elixir
defmodule MyApp.CategoryProjector do
  use Dobro.App.Projector,
    stream_name: MyApp.Category.__stream_name__()

  def project(%MyApp.CategoryEvents.CategoryCreated{payload: %{id: id}}) do
    :ok
  end

  def project(_), do: :ok
end
```

Projectors track position in `projection_versions` for idempotent at-least-once processing.

---

## Aggregate persistence (infra)

| Module | Role |
|--------|------|
| `Dobro.Infra.Data.WriteRepo.Persist` | Save aggregate snapshots through WriteRepo ports |
| `Dobro.Infra.Data.WriteRepo.Operation` | Resolve `:insert`, `:update`, or `:delete` |
| `Dobro.Infra.Repo` | Transaction wrapper around configured Ecto repo |

Event enrichment lives in `dobro_cqrs` (`Dobro.App.Command.EventEnrichment`). Persistence strategies orchestrate both.

---

## Main modules

| Module | Role |
|--------|------|
| `Dobro.Infra.Data.ReadRepo` | Read repo macro |
| `Dobro.Infra.Data.WriteRepo` | Write repo macro |
| `Dobro.Infra.Data.Query.Definition` | **`defquery` compiler (infrastructure)** |
| `Dobro.Query.List` | List query execution engine |
| `Dobro.App.Projector` | Event projection macro |
| `Dobro.Tenant.Resolver` | Schema-prefix tenant behaviour |
| `Dobro.Infra.Data.WriteRepo.Persist` | Stateful aggregate snapshot writes |
| `Dobro.App.EventStore` | Append-only domain event storage |

---

## Related packages

- [dobro_cqrs](https://hexdocs.pm/dobro_cqrs) — **application** queries and handlers that call read repos
- [dobro_domain](https://hexdocs.pm/dobro_domain) — aggregates and events that write repos persist
- [dobro_runtime](https://hexdocs.pm/dobro_runtime) — write orchestration and event broadcast

## License

MIT
