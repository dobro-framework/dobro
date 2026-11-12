# [AGENTS.md](http://AGENTS.md)

Dobro is a framework. Changes here stay general: no Application specific column names, no Oban, no host-app modules.

## Model

Domain code does not import Ecto, HTTP, or PubSub. State changes are events: `add_event`, then `apply_changes` / `defapply`. Do not add a second way to mutate an aggregate.

Ports are how application code reaches infrastructure. A new capability gets a port, an adapter, and a registry entry.

## Identity, tenancy, mappings

Aggregate identity is the `identity do` block. The macro injects those fields. Callers do not redeclare them on `state`. `load :optional` is declared on the command. The default is `load :required`.

Do not add command or query scope modes. The `scope` macro is a no-op. Tenancy is `%TenantContext{}` or `%GlobalContext{}` on the execution context. `Dobro.App.Api.Middleware.Tenant` checks that against the route's surfaces. `Dobro.App.ScopePolicy` checks it against the repo's `scopes` and `tenant_strategy`. A nil tenant is not a stand-in for global.

Write-repo mappings are generic field and association mappings. A missing link-table or preload behaviour is a WriteRepo feature, not something each app overrides by replacing repo functions.

## Transports and events

Enums, commands, and queries are defined in the application layer. GraphQL, and later REST or a CLI, project them. Transport details do not go in the domain.

GraphQL route surfaces are additive. A module-level `surfaces:` list applies to every route, and a route's own `surfaces:` are appended. With no module list, each route opts itself in.

Integration events are a pluggable bus. Subscribers do not know the backing store. Dobro does not depend on Oban. The host application chooses the job runner.

Domain event streams stay per aggregate. Integration topics stay per bounded context. `wait_for: wait_for_projection(...)` is for a response that reads that projection immediately. It is not how later screens stay up to date.

## Formatting

New DSL macros go in `locals_without_parens` and are exported so host apps can import them.