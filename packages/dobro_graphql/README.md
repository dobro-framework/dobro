# Dobro GraphQL

Generate Absinthe GraphQL schemas from Dobro API modules — including typed inputs, result objects, mutations with structured error payloads, and field selection for efficient queries.

Use this package when your transport layer is GraphQL and your application logic is already defined with `Dobro.App.Api` routes in `dobro_cqrs`.

## Requirements

- Elixir ~> 1.14
- Absinthe ~> 1.7
- [absinthe_error_payload](https://hexdocs.pm/absinthe_error_payload) ~> 1.0
- [dobro_cqrs](https://hexdocs.pm/dobro_cqrs) and its dependencies ~> 0.1

## Installation

```elixir
def deps do
  [
    {:dobro_graphql, "~> 0.1.0"},
    {:absinthe, "~> 1.7"},
    {:absinthe_error_payload, "~> 1.0"}
  ]
end
```

## Overview

Dobro GraphQL reads your **application API** module definitions from `dobro_cqrs` — routes, command/query payloads, result contracts, and scope — and generates Absinthe object types, input types, query fields, and mutation fields automatically.

It does **not** read infrastructure `defquery` definitions from read repos. GraphQL fields map to application queries (for example `CategoryQueries.ListCategories`), which in turn delegate to read repo functions.

Add a route to your API module, recompile, and the corresponding GraphQL field appears.

## Schema integration

Create a schema module that imports one or more Dobro API modules:

```elixir
defmodule MyAppWeb.Schema do
  use Absinthe.Schema

  defmodule ApiSchema do
    use Dobro.Graphql.Schema

    api MyApp.Users.UsersApi
    api MyApp.Orders.OrdersApi
  end

  import_types(Absinthe.Type.Custom)
  import_types(ApiSchema)
  import_types(AbsintheErrorPayload.ValidationMessageTypes)
end
```

Each `api/1` call expands into GraphQL query and mutation fields for every route defined in the API module. Type names are derived from the API module's context namespace to avoid collisions across bounded contexts.

### Generated field naming

For an API module `MyApp.Users.UsersApi` with context `{MyApp.Users, :users}`:

| API route | GraphQL field (example) |
|-----------|-------------------------|
| `:get_user` | `users_get_user` |
| `:list_users` | `users_list_users` |
| `:register_user` | `users_register_user` |

Exact naming follows the namespace configured in the API module's `:context` option.

## Queries

GraphQL query fields are generated from **application query routes** in your API module — not from infrastructure `defquery` definitions:

```elixir
# Application route (dobro_cqrs) → GraphQL query field
route :list_categories,
  query: CategoryQueries.ListCategories,
  to: CategoryQueries.Handler,
  policy: @read,
  result: CategoryList
```

The generated field accepts arguments matching the application query payload (including nested `Query` input for list filtering/pagination) and returns a typed result object cast from the handler result.

## Mutations

Command routes generate mutation fields with input types, optional identity arguments, and payload-wrapped results compatible with `absinthe_error_payload`:

```elixir
# In UsersApi
route :update_user,
  command: UserCommands.UpdateUser,
  to: UserCommands.Handler,
  policy: @manage,
  returning: :get_user
```

Mutations return a result type that includes both successful data and structured validation errors. Dobro validation errors (`Dobro.Error`) are mapped to GraphQL-friendly messages automatically.

### Tenant-scoped mutations

When a command declares `scope :tenant, from: :payload`, the generated mutation input includes a required `tenant_id` field.

## Field selection

GraphQL field selections are translated into `Dobro.App.Selection` values and passed through `ExecutionContext` to read repositories. This allows list and detail queries to fetch only the columns and associations the client requested:

```elixir
# Selection is attached automatically by Dobro GraphQL resolvers.
# Read repos use it to limit selected columns and joins.
selection = Dobro.Graphql.Selection.from_resolution(resolution, MyApp.UserListItem)
context = Dobro.App.ExecutionContext.new(selection: selection)
```

When selection is `nil`, repositories return all declared fields — useful for non-GraphQL callers.

### How selection flows

```
GraphQL query
  → Absinthe resolution
  → Dobro.Graphql.Selection.from_resolution/2
  → ExecutionContext.selection
  → Query handler
  → Read repo (applies selection to query)
```

## Error payloads

Mutations use [absinthe_error_payload](https://hexdocs.pm/absinthe_error_payload) for consistent error shapes:

```json
{
  "data": {
    "users_register_user": {
      "successful": false,
      "messages": [
        { "field": "email", "message": "has already been taken" }
      ],
      "result": null
    }
  }
}
```

Validation errors from `Dobro.Error` structs include field paths. Domain errors from command handlers are mapped to the same payload structure.

## Custom type extensions

Import additional Absinthe types alongside the generated schema:

```elixir
import_types(Absinthe.Type.Custom)
import_types(AbsintheJsonScalar)
import_types(AbsintheErrorPayload.ValidationMessageTypes)
```

Use `Dobro.Graphql.Schema.JSON` for a JSON scalar when needed.

## Main modules

| Module | Role |
|--------|------|
| `Dobro.Graphql.Schema` | Schema macro with `api/1`, `api_query/2`, `api_mutation/2` |
| `Dobro.Graphql.Selection` | Absinthe resolution → `Dobro.App.Selection` |
| `Dobro.Graphql.Schema.MutationBuilder` | Mutation field and input type generation |
| `Dobro.Graphql.Schema.JSON` | JSON scalar type |
| `Dobro.Graphql.Helpers` | Shared naming and type-building utilities |

## Related packages

- [dobro_cqrs](https://hexdocs.pm/dobro_cqrs) — defines the API routes this package exposes
- [dobro_ecto](https://hexdocs.pm/dobro_ecto) — read repos consume field selections
- [dobro_domain](https://hexdocs.pm/dobro_domain) — `ExecutionContext` and `Selection` types

## License

MIT
