# Dobro CQRS

Application-layer patterns for commands, queries, handlers, scope validation, and public API definitions.

This package is the **application layer** of Dobro. It defines use cases — what callers can ask for — and delegates reads and writes to infrastructure ports. It does **not** contain Ecto queries; those live in `dobro_ecto` read repositories.

## Requirements

- Elixir ~> 1.14
- [dobro_ecto](https://hexdocs.pm/dobro_ecto) and its dependencies ~> 0.1
- [dobro_runtime](https://hexdocs.pm/dobro_runtime) ~> 0.1 — **optional**; required for commands with identity and for PubSub event broadcast

## Installation

### Minimal (synchronous commands, no PubSub)

```elixir
def deps do
  [
    {:dobro_cqrs, "~> 0.1.0"},
    {:dobro_ecto, "~> 0.1.0"}
  ]
end
```

### With aggregate actors and event delivery

```elixir
def deps do
  [
    {:dobro_cqrs, "~> 0.1.0"},
    {:dobro_ecto, "~> 0.1.0"},
    {:dobro_runtime, "~> 0.1.0"}
  ]
end
```

## Application vs infrastructure queries

Dobro has **two distinct query layers**. Confusing them is a common source of errors.

| Layer | Package | Macro | Defines | Example |
|-------|---------|-------|---------|---------|
| **Application query** | `dobro_cqrs` | `query` in `QueryDefinition` | Use-case input (scope, payload) exposed via API/GraphQL | `CategoryQueries.ListCategories` |
| **Infrastructure query** | `dobro_ecto` | `defquery` in `ReadRepo` | Ecto SQL, joins, filterable/sortable fields | `CategoryReadRepo.list_categories/1` |

They connect through the **query handler**, which maps an application query to a **read repo function name**:

```elixir
# Application layer (this package)
query_handler Handler, repo: CategoryReadRepo do
  handle ListCategories, :list_categories   # ← repo function atom
end

# Infrastructure layer (dobro_ecto) — see dobro_ecto README
defquery ListCategories, type: :list do
  # Ecto query definition ...
end
```

The handler passes the application query payload (as a plain map/DTO) as the first argument to the repo function. For list queries, filtering and pagination travel in a `Dobro.App.Types.Query` field on that payload.

### Query read path

```
API route / GraphQL field
  → Application query struct (QueryDefinition)
  → Query handler (QueryHandler)
      → scope validation (ScopePolicy vs read repo)
      → read repo function (infra adapter)
          → defquery implementation (Ecto)
  → Result DTO
```

Commands follow a parallel write path through command handlers and write repos — see [Command execution flow](#command-execution-flow) below.

---

## Configuration

Command handling is configured through three independent strategies:

| Key | Default | Role |
|-----|---------|------|
| `:execution_strategy` | `:actor_when_identified` | How aggregate functions run (`:inline`, `:actor`, …) |
| `:persistence_strategy` | `:stateful` | How state and events are stored (`:stateful`, `:event_sourced`) |
| `:event_delivery_strategy` | `:none` | How events reach subscribers (`:none`, `:pubsub`, `:outbox`) |

FM production configuration:

```elixir
config :dobro_cqrs,
  execution_strategy: :actor_when_identified,
  persistence_strategy: :stateful,
  event_delivery_strategy: :pubsub

config :dobro_runtime,
  pubsub: MyApp.PubSub,
  outbox_relay: [
    enabled: false,
    batch_size: 100,
    poll_interval_ms: 1_000,
    claim_timeout_ms: 300_000,
    purge_after_ms: nil,
    purge_interval_ms: 60_000
  ]
```

Per-handler and per-handle overrides are supported — see [Command Strategies RFC](command-strategies.html).

Commands that declare an **`identity`** block require `dobro_runtime` when using `:actor_when_identified` or `:actor`. Without runtime, handlers return a `:runtime_required` error.

---

## Commands

Commands represent write use cases. Define them in a `CommandDefinition` module:

```elixir
defmodule MyApp.Archive.App.CategoryCommands do
  use Dobro.App.CommandDefinition
  alias MyApp.Archive.Domain.Category

  defcontract CreateCategoryInput do
    field :tenant_id, :id
    field :parent_id, :id
    field :name, :string
    field :identifier, :string
  end

  defcontract UpdateCategoryInput do
    field :tenant_id, :id
    field :parent_id, :id
    field :name, :string
    field :identifier, :string
  end

  command CreateCategory do
    scope :global
    payload CreateCategoryInput
  end

  command UpdateCategory do
    scope :global

    identity do
      field :id, :id
    end

    payload UpdateCategoryInput
  end

  command_handler Handler, aggregate: Category do
    handle CreateCategory, :create, contract: Category.Create
    handle UpdateCategory, :update, contract: Category.Update
  end
end
```

### Scope

Every command and query declares a scope:

| Scope | Declaration | Meaning |
|-------|-------------|---------|
| `:global` | `scope :global` | No tenant context required |
| `:tenant` | `scope :tenant, from: :context` | Tenant from `ExecutionContext` |
| `:tenant` | `scope :tenant, from: :payload` | Tenant ID on the command/query payload |
| `:dynamic` | `scope :dynamic` | Global or tenant depending on context |

### Identity

Commands targeting an existing aggregate declare an identity block:

```elixir
identity do
  field :id, :id
end
```

Create commands omit identity and run synchronously. Update/delete commands with identity require `dobro_runtime` when using actor-based execution.

### Payload

Attach a typed input contract:

```elixir
payload CreateCategoryInput          # named contract module

payload do                           # inline payload
  field :email, :string, required: true
end
```

---

## Command handlers

Command handlers connect commands to aggregate functions. They can be defined inline in the same module as commands (as above) or in a separate module using `Dobro.App.CommandHandler`.

### Handler options

| Option | Purpose |
|--------|---------|
| `:contract` | Aggregate contract module for input casting |
| `:if` | Specifications that must pass before execution |
| `:identify` | Identity resolution — `:get`, `:get_by`, or custom function |
| `:transform_payload` | Reshape input before contract casting |
| `:transform_result` | Reshape the handler result |

### Command execution flow

```
Public API route
  → Command handler
  → Scope setup
  → Contract casting
  → Specification checks (`if:`)
  → Identity resolution (if declared)
  → Execution strategy (inline or actor)
      → Aggregate function (event pipeline)
      → Command.Commit
          → Persistence strategy (stateful or event-sourced)
          → Event delivery strategy (none, pubsub, or outbox)
  → Result
```

Every command follows the same event-driven domain path defined in [dobro_domain](https://hexdocs.pm/dobro_domain). Execution, persistence, and event delivery strategies control concurrency, storage, and fan-out.

---

## Application queries

Application queries define **what callers can read** — their scope, input fields, and which read repo function satisfies them. They live in `QueryDefinition` modules:

```elixir
defmodule MyApp.Archive.App.CategoryQueries do
  use Dobro.App.QueryDefinition

  alias Dobro.App.Types.Query
  alias MyApp.Archive.Ports.CategoryReadRepo

  query GetCategory do
    scope :global

    payload do
      field :id, :id, required: true
    end
  end

  query ListCategories do
    scope :global

    payload do
      field :tenant_id, :id
      field :query, Query
    end
  end

  query_handler Handler, repo: CategoryReadRepo do
    handle GetCategory, :get_category
    handle ListCategories, :list_categories
  end
end
```

### What an application query is

An application query module (for example `CategoryQueries.ListCategories`) is a **typed struct** representing a use case:

- **`scope`** — who can run this query and under what tenant rules
- **`payload`** — the input fields the caller provides (IDs, filters, pagination wrapper)

It does **not** contain SQL, Ecto bindings, joins, or `filterable`/`sortable` declarations. Those belong to the infrastructure `defquery` in [dobro_ecto](https://hexdocs.pm/dobro_ecto).

### List query pagination and filtering

For paginated lists, include `Dobro.App.Types.Query` on the application query payload:

```elixir
alias Dobro.App.Types.Query

query ListCategories do
  scope :global

  payload do
    field :tenant_id, :id          # application-level filter
    field :query, Query            # page, page_size, filters, order
  end
end
```

`Dobro.App.Types.Query` carries:

| Field | Purpose |
|-------|---------|
| `:page`, `:page_size` | Pagination |
| `:limit` | Alternative to page-based pagination |
| `:filters` | List of `%{field, op, value}` filter clauses |
| `:order` | List of `%{field, direction}` sort clauses |

The query handler converts the application query struct to a plain map (`DTO.to_dto/1`) and passes it to the repo function. The infrastructure `defquery` interprets `args[:query]` against its declared `filterable` and `sortable` fields.

### Exists and custom queries

Not every read goes through `defquery`. Read repos can expose plain functions for simple checks:

```elixir
# Application query
query OfficeExistsForTenant do
  scope :tenant, from: :payload

  payload do
    field :tenant_id, :id, required: true
  end
end

query_handler Handler, repo: OfficeReadRepo do
  handle OfficeExistsForTenant, :office_exists_for_tenant?
end
```

```elixir
# Infrastructure adapter (dobro_ecto) — custom function, no defquery
def office_exists_for_tenant?(_input, %Context{} = context) do
  schema() |> exists?(context: context)
end
```

The handler always references a **repo function atom** — whether generated by `defquery` or written by hand.

---

## Query handlers

Query handlers validate scope, call the read repo, and return results.

```elixir
query_handler Handler, repo: CategoryReadRepo do
  handle GetCategory, :get_category
  handle ListCategories, :list_categories
end
```

### Generated handler behaviour

For `handle QueryModule, :repo_function`, the handler:

1. Initialises a pipeline from the application query struct
2. Resolves scope via `Dobro.App.Scope.setup_for_query!/2`
3. Validates scope against the repo via `Dobro.App.ScopePolicy.validate!/2`
4. Converts the query payload to a DTO map
5. Calls `CategoryReadRepo.adapter().repo_function(dto, context)` (or `/1` for global repos)
6. Returns `{:ok, result}` or `{:error, errors}`

When an `ExecutionContext` with field selection is present (from GraphQL), it is passed as `ReadRepo.Context` so infrastructure queries can limit selected columns.

### Custom handler logic

For queries that compose multiple repo calls or apply application logic, use a custom `handle` block:

```elixir
query_handler Handler, repo: CategoryReadRepo do
  handle GetCategory, :get_category
  handle ListCategories, :list_categories

  handle EnrichedCategoryList, query, execution_context do
    pipeline(query, execution_context)
    |> call(:list_categories)
    |> bind(fn pipeline ->
      categories = get_from_workspace(pipeline, :list_categories)
      # enrich, transform, etc.
      put_result(pipeline, enriched(categories))
    end)
    |> finalize(:result)
  end
end
```

---

## Worked example: categories end-to-end

This shows how application and infrastructure queries connect across packages.

### 1. Port (`dobro_spec` + `dobro_ecto`)

```elixir
defmodule MyApp.Archive.Ports.CategoryReadRepo do
  use Dobro.Infra.Data.ReadRepo.PortDefinition
end
```

### 2. Infrastructure query (`dobro_ecto`)

```elixir
defmodule MyApp.Archive.Infra.CategoryReadRepo do
  use Dobro.Infra.Data.ReadRepo,
    port: MyApp.Archive.Ports.CategoryReadRepo,
    schema: MyApp.Archive.CategorySchema,
    scopes: [:global]

  defquery ListCategories, type: :list do
    join :tenant, type: :left do
      field :tenant_name, :name, filterable: true, sortable: true
    end

    filterable [:name, :identifier, :tenant_name]
    sortable [:id, :name, :identifier, :tenant_name]

    query fn args, _context ->
      from(c in schema(), as: :category)
      |> maybe_apply_tenant(args[:tenant_id], include_global: true)
    end
  end

  defquery GetCategory, type: :one do
    preload :tenant, MyApp.Tenants.TenantSchema, fields: [:id, :name]
  end
end
```

### 3. Application query (`dobro_cqrs` — this package)

```elixir
defmodule MyApp.Archive.App.CategoryQueries do
  use Dobro.App.QueryDefinition
  alias Dobro.App.Types.Query
  alias MyApp.Archive.Ports.CategoryReadRepo

  defcontract Category do
    field :id, :id
    field :name, :string
    field :identifier, :string
  end

  defcontract CategoryList do
    field :meta, Dobro.App.Types.Pagination
    field :items, list_of(Category)
  end

  query GetCategory do
    scope :global
    payload do
      field :id, :id, required: true
    end

    result Category
  end

  query ListCategories do
    scope :global
    payload do
      field :tenant_id, :id
      field :query, Query
    end

    result CategoryList
  end

  query_handler Handler, repo: CategoryReadRepo do
    handle GetCategory, :get_category
    handle ListCategories, :list_categories
  end
end
```

### 4. Public API route (`dobro_cqrs`)

```elixir
defmodule MyApp.Archive.ArchiveApi do
  use Dobro.App.Api,
    port: MyApp.Archive.Ports.ArchiveApi,
    context: {MyApp.Archive, :archive}

  alias MyApp.Archive.App.CategoryQueries

  route :get_category,
    query: CategoryQueries.GetCategory,
    to: CategoryQueries.Handler,
    policy: :archive_read

  route :list_categories,
    query: CategoryQueries.ListCategories,
    to: CategoryQueries.Handler,
    policy: :archive_read
end
```

Query and command modules declare `result` next to `payload`. Routes infer that type; pass `result:` only to override it.

---

## Public API

API modules group commands and queries into a bounded context's public interface:

```elixir
defmodule MyApp.Archive.ArchiveApi do
  use Dobro.App.Api,
    port: MyApp.Archive.Ports.ArchiveApi,
    context: {MyApp.Archive, :archive}

  @read :archive_read
  @manage :archive_manage

  route :list_categories,
    query: CategoryQueries.ListCategories,
    to: CategoryQueries.Handler,
    policy: @read

  route :create_category,
    command: CategoryCommands.CreateCategory,
    to: CategoryCommands.Handler,
    policy: @manage,
    returning: :get_category
end
```

### Route options

| Option | Applies to | Purpose |
|--------|------------|---------|
| `:query` / `:command` | Both | Application query or command module |
| `:to` | Both | Handler module |
| `:policy` | Both | Authorisation (host application concern) |
| `:result` | Both | Optional override of the message's `result` type |
| `:returning` | Command | Route name to invoke after mutation for response shape |

API modules are port adapters. Invoke them directly or expose via GraphQL through [dobro_graphql](https://hexdocs.pm/dobro_graphql).

---

## Shared application types

| Module | Purpose |
|--------|---------|
| `Dobro.App.Types.Query` | Pagination, filtering, and sorting input for list queries |
| `Dobro.App.Types.Pagination` | Pagination metadata in list results |
| `Dobro.App.Types.Identified` | `{id}` result after persist when the public shape comes from `returning:` |
| `Dobro.App.Types.Deleted` | `{id}` result for delete commands |
| `Dobro.App.Types.Filter` | Single filter clause (`field`, `op`, `value`) |
| `Dobro.App.Types.Sort` | Sort clause (`field`, `direction`) |

These types appear on **application query payloads and API result contracts**. Infrastructure `defquery` modules declare which fields accept filters and sorts.

---

## Command strategies

| Module | Role |
|--------|------|
| `Dobro.App.Command.Strategy` | Resolves execution, persistence, and delivery strategies |
| `Dobro.App.Command.Commit` | Shared transaction and delivery orchestration |
| `Dobro.App.Command.ExecutionStrategy.*` | Inline, actor-when-identified |
| `Dobro.App.Command.PersistenceStrategy.*` | Stateful (default), event-sourced |
| `Dobro.App.Command.EventDeliveryStrategy.*` | None (default), pubsub, outbox |
| `Dobro.App.Command.EventEnrichment` | Enriches events during commit |
| `Dobro.Cqrs.Config` | Resolves configured strategy keys |

See [Command Strategies RFC](command-strategies.html) for override and combination details.

---

## Main modules

| Module | Role |
|--------|------|
| `Dobro.App.CommandDefinition` | Define commands and inline command handlers |
| `Dobro.App.QueryDefinition` | Define **application** queries and inline query handlers |
| `Dobro.App.CommandHandler` | Command handler macro |
| `Dobro.App.CommandHandler.Pipeline` | Command pipeline steps |
| `Dobro.App.QueryHandler` | Query handler macro |
| `Dobro.App.QueryHandler.Pipeline` | Query pipeline — scope, repo call, finalize, prepare_input |
| `Dobro.App.Api` | Public API route DSL |
| `Dobro.App.Types` | Shared Query, Pagination, Identified, Deleted, Filter, Sort types |
| `Dobro.Cqrs.Config` | Strategy configuration |

Scope, scope policy, and event handlers live in [dobro_domain](https://hexdocs.pm/dobro_domain). Infrastructure `defquery` lives in [dobro_ecto](https://hexdocs.pm/dobro_ecto).

---

## Related packages

- [dobro_ecto](https://hexdocs.pm/dobro_ecto) — read/write repos and **infrastructure** `defquery` definitions
- [dobro_domain](https://hexdocs.pm/dobro_domain) — aggregates invoked by command handlers
- [dobro_runtime](https://hexdocs.pm/dobro_runtime) — aggregate actors and PubSub (optional)
- [dobro_graphql](https://hexdocs.pm/dobro_graphql) — expose API routes over Absinthe

## License

MIT
