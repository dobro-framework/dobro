# Dobro Schema

Define typed structs, validate input, and build input contracts — without Ecto or a database.

This package provides the validation foundation used throughout Dobro: declarative field definitions, a pipeline for accumulating errors, and contract macros for API payloads, command inputs, and aggregate contracts.

## Requirements

- Elixir ~> 1.14

## Installation

```elixir
def deps do
  [{:dobro_schema, "~> 0.1.0"}]
end
```

### Optional validators

Some field types require additional dependencies:

```elixir
{:ex_phone_number, "~> 0.4"},   # :phone_number validation on strings
{:timex, "~> 3.7"}              # flexible datetime parsing
```

## Schemas

Declare fields on a struct module with the `Dobro.Schema` macro:

```elixir
defmodule MyApp.UserInput do
  use Dobro.Schema

  schema do
    field :email, :string, validate: [:presence, :email]
    field :name, :string, required: true
    field :age, :integer
    field :tags, list_of(:string)
  end
end
```

### Supported types

| Category | Types |
|----------|-------|
| Primitives | `:string`, `:integer`, `:float`, `:boolean`, `:datetime`, `:map`, `:id` |
| Composites | `list_of/1`, `non_null/1`, `one_of/2` |
| Custom | Any module implementing the schema type protocol |

### Validation

Validators are declared per field:

```elixir
field :email, :string, validate: [:presence, :email]
field :name, :string, validate: [{:min_length, 3}]
field :status, :string, validate: [inclusion: ["active", "inactive"]]
```

## Contracts

Contracts extend schemas with a casting API for maps and keyword lists. Use them for HTTP payloads, command inputs, and aggregate operation contracts:

```elixir
defmodule MyApp.Api.CreateUser do
  use Dobro.Contract

  defcontract Input do
    schema do
      field :email, :string, validate: [:presence, :email]
      field :name, :string, required: true
    end
  end
end
```

### Casting

```elixir
MyApp.Api.CreateUser.Input.new(%{"email" => "a@example.com", "name" => "Ada"})
#=> {:ok, %MyApp.Api.CreateUser.Input{email: "a@example.com", name: "Ada"}}

MyApp.Api.CreateUser.Input.new!(%{"email" => "bad"})
#=> raises on validation failure
```

Validation errors are returned as a list of `Dobro.Error` structs with field paths. List items include indexed paths such as `"tags[1]"`.

## Pipeline and state

`Dobro.Pipeline` provides monadic error accumulation — each step either continues or adds errors without short-circuiting early validation. `Dobro.State` assigns coerced values into schema structs.

You typically use these through `Dobro.Contract` and aggregate macros rather than calling them directly. Command handlers and aggregates build on the same pipeline primitives.

## Domain value hydration

`Dobro.Schema.DomainValue` converts persisted primitive values into domain types when loading from the database or applying events:

```elixir
# A string column becomes a validated EmailAddress value object
field :email, MyApp.EmailAddress
```

## Error structure

```elixir
%Dobro.Error{
  reason: :invalid_email,
  field: "email",
  description: "is not a valid email address"
}
```

Errors compose: a contract with multiple invalid fields returns all errors in one `{:error, errors}` tuple.

## Main modules

| Module | Role |
|--------|------|
| `Dobro.Schema` | Field definitions and struct generation |
| `Dobro.Contract` | Input DTO macro with `new/1`, `new!/1`, and `cast/1` |
| `Dobro.Pipeline` | Monadic error accumulation for multi-step operations |
| `Dobro.State` | Assign and hydrate values into schema structs |
| `Dobro.Error` | Structured validation and domain errors |
| `Dobro.Schema.DomainValue` | Hydrate persisted values into domain types |
| `Dobro.Schema.Types` | Built-in type implementations and validators |

## Related packages

- [dobro_domain](https://hexdocs.pm/dobro_domain) — aggregates and value objects built on schemas
- [dobro_spec](https://hexdocs.pm/dobro_spec) — ports often sit alongside contracts at system boundaries
- [dobro_cqrs](https://hexdocs.pm/dobro_cqrs) — command and query payloads use contracts

## License

MIT
