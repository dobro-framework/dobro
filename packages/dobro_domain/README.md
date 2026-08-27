# Dobro Domain

Domain-driven design building blocks for Elixir: aggregates, value objects, domain events, specifications, execution context, and event handlers.

Use this package to model business rules and domain structure in isolation from databases, HTTP, GraphQL, and other infrastructure. The programming model is **event-centric** — every aggregate mutation records domain events and applies them to in-memory state before anything is persisted. Whether you store aggregate snapshots or rebuild state from an event stream downstream, the domain code stays the same.

## Requirements

- Elixir ~> 1.14
- [dobro_schema](https://hexdocs.pm/dobro_schema) ~> 0.1

## Installation

```elixir
def deps do
  [
    {:dobro_domain, "~> 0.1.0"},
    {:dobro_schema, "~> 0.1.0"}
  ]
end
```

## Concepts

| Concept | Module | Purpose |
|---------|--------|---------|
| Aggregate | `Dobro.Domain.Aggregate` | Consistency boundary; all mutations produce events |
| Value object | `Dobro.Domain.ValueObject` | Immutable, validated types compared by value |
| Domain event | `Dobro.Domain.EventDefinition` | Typed, versioned record of something that happened |
| Specification | `Dobro.Domain.Specification` | Precondition checked before a command runs |
| Event handler | `Dobro.App.EventHandler` | Reacts to published domain events |
| Execution context | `Dobro.App.ExecutionContext` | Auth, tenant, and selection passed to handlers |

## Event-driven state transitions

Every aggregate operation follows the same pipeline, regardless of persistence strategy:

```
Input (contract)
  → pipeline/1 or pipeline/2
  → add_event/2 or add_event/3
  → apply_changes/1
  → {:ok, %{value: aggregate, events: events}}
     — or —
  → {:error, errors}
```

1. **Record intent** — `add_event/3` appends one or more domain events against the current aggregate state.
2. **Apply events** — `apply_changes/1` versions each event, applies it to the aggregate via `defapply/2`, and increments `version`.
3. **Verify invariants** — business rules declared with `definvariant/2` are checked on the resulting state.
4. **Return result** — the updated aggregate and event list are handed to the command handler for persistence.

This is the same model used by frameworks like Axon: events are the source of truth for *what changed*; the storage layer decides *how* that change is recorded (stateful tables today, event streams at release).

---

## Value objects

Value objects wrap validated data. They are immutable, compared by value, and reusable as field types in aggregates, contracts, and events.

Dobro provides two patterns.

### Singular value objects

For a single wrapped value (email, phone number, URL, identifier):

```elixir
defmodule MyApp.EmailAddress do
  use Dobro.Domain.ValueObject.Singular,
    type: :string,
    validate: [{:format, "^[^\\s]+@[^\\s]+$"}]
end

MyApp.EmailAddress.new("user@example.com")
#=> {:ok, %MyApp.EmailAddress{value: "user@example.com"}}

MyApp.EmailAddress.new("not-an-email")
#=> {:error, [%Dobro.Error{...}]}

# Extract the raw value
MyApp.EmailAddress.value(%MyApp.EmailAddress{value: "user@example.com"})
#=> "user@example.com"
```

Singular value objects also accept a bare string in `new/1`:

```elixir
MyApp.EmailAddress.new("user@example.com")
```

### Composite value objects

For structured data with multiple fields:

```elixir
defmodule MyApp.Address do
  use Dobro.Domain.ValueObject

  schema do
    field :company_name, :string
    field :address_line1, :string, required: true
    field :address_line2, :string
    field :town, :string, required: true
    field :postcode, :string, required: true, validate: [{:format, "^[A-Z0-9 ]+$"}]
    field :country, :string
  end
end

MyApp.Address.new(%{
  address_line1: "1 High Street",
  town: "London",
  postcode: "SW1A 1AA"
})
#=> {:ok, %MyApp.Address{...}}
```

### Loading from persistence

Use `load/1` when hydrating from a database row or event payload — validation and invariants are skipped:

```elixir
MyApp.Address.load(%{
  address_line1: "1 High Street",
  town: "London",
  postcode: "SW1A 1AA"
})
#=> {:ok, %MyApp.Address{...}}

MyApp.EmailAddress.load("user@example.com")
#=> {:ok, %MyApp.EmailAddress{value: "user@example.com"}}
```

Use `new/1` at system boundaries (API input, command payloads) where validation must run.

### Invariants on value objects

Value objects support the same `definvariant/2` macro as aggregates:

```elixir
defmodule MyApp.Age do
  use Dobro.Domain.ValueObject.Singular, type: :integer

  definvariant must_be_positive(%{value: age}) when age > 0, do: :ok
  definvariant must_be_positive(_), do: {:error, :must_be_positive}
end
```

### Using value objects in aggregates

Reference value object modules directly as field types:

```elixir
state do
  field :email_address, MyApp.EmailAddress
  field :address, MyApp.Address, required: true
end
```

When persisting or serialising events, use `Dobro.Domain.ValueObject.value/1` to extract plain data.

---

## Aggregates

An aggregate is the consistency boundary for a cluster of domain objects. All changes go through explicit functions that emit events.

### Complete example

The following is adapted from a real bounded context — an `Office` aggregate with create and update operations, value object fields, contracts, events, and invariants:

```elixir
defmodule MyApp.Office do
  use Dobro.Domain.Aggregate

  alias MyApp.{Address, EmailAddress, PhoneNumber, Url}
  alias MyApp.OfficeEvents, as: Events

  # Aggregate state — persisted fields
  state do
    field :id, :id, immutable: true
    field :name, :string, required: true, validate: [{:min_length, 3}]
    field :abbreviation, :string, required: true
    field :phone_number, PhoneNumber
    field :email_address, EmailAddress
    field :website_url, Url
    field :address, Address, required: true
  end

  # Input contracts — one per operation
  defcontract Create do
    field :name, :string, required: true
    field :abbreviation, :string, required: true
    field :phone_number, PhoneNumber
    field :email_address, EmailAddress
    field :website_url, Url
    field :address, Address, required: true
  end

  defcontract ChangeAddress do
    field :address, Address, required: true
  end

  # Create — no existing aggregate
  def create(%Create{} = input) do
    pipeline(input)
    |> add_event(Events.OfficeCreated)
    |> apply_changes()
  end

  # Update — existing aggregate as first argument
  def change_address(%__MODULE__{} = office, %ChangeAddress{} = input) do
    pipeline(office, input)
    |> add_event(Events.OfficeAddressChanged)
    |> apply_changes()
  end

  # Event application — how each event mutates state
  defapply Events.OfficeCreated
  defapply Events.OfficeAddressChanged, [:address]

  # Invariants — checked after all events are applied
  definvariant must_have_contact(%{email_address: email}) when not is_nil(email), do: :ok
  definvariant must_have_contact(%{phone_number: phone}) when not is_nil(phone), do: :ok
  definvariant must_have_contact(_), do: {:error, :must_have_contact}
end
```

### State fields

The `state do` block declares persisted aggregate fields. Every aggregate includes a required `version` field automatically (default `0` for new instances).

| Option | Effect |
|--------|--------|
| `required: true` | Field must be present after event application |
| `immutable: true` | Field cannot change once set (for example `:id`) |
| `validate: [...]` | Validation rules from `dobro_schema` |
| Custom type module | Value object or nested contract type |

### Operation contracts

Each aggregate function accepts a typed contract defined with `defcontract`. Command handlers cast command payloads into these contracts before calling the aggregate:

```elixir
defcontract Update do
  field :name, :string
  field :identifier, :string
end
```

Contracts are independent of aggregate state — they describe the input to a single operation.

### The aggregate pipeline

#### Starting a pipeline

```elixir
# Create — no existing aggregate
pipeline(%Create{name: "HQ", abbreviation: "HQ", address: address})

# Update — pass existing aggregate and input contract
pipeline(existing_office, %ChangeAddress{address: new_address})
```

#### Recording events

Pass an event module (payload built from contract input):

```elixir
|> add_event(Events.OfficeCreated)
```

Or pass the event module with a post-transform `(aggregate, attrs) -> attrs` when the
payload is mostly convention-mapped but needs a few extra fields:

```elixir
|> add_event(Events.UserInvited, fn user, attrs ->
  Map.merge(attrs, %{email: user.email, username: user.username, invitation_accepted_at: nil})
end)

|> add_event(Events.UserDeleted, &with_deleted_at/2)
```

Or pass a builder function `(aggregate, input) -> event` for fully custom assembly:

```elixir
|> add_event(&office_deleted_event/2)

def office_deleted_event(%__MODULE__{id: id}, _input) do
  Events.OfficeDeleted.new(%{
    payload: %{id: id, deleted_at: DateTime.utc_now(:microsecond)}
  })
end
```

#### Conditional events

Emit events only when specific fields changed, using `changed?/1` from `Dobro.State`:

```elixir
def update(%__MODULE__{} = category, %Update{} = input) do
  pipeline(category, input)
  |> add_event(Events.CategoryMoved, &Map.put(&2, :original_parent_id, &1.parent_id),
    if: changed?(:parent_id)
  )
  |> add_event(Events.CategoryRenamed, &Map.put(&2, :original_name, &1.name),
    if: changed?(:name)
  )
  |> apply_changes()
end
```

`changed?(:field)` expands to `{:changed, :field}`, which compares the aggregate's current value with the contract input.

#### Applying changes

```elixir
|> apply_changes()
```

This step:

1. Assigns a monotonically increasing `version` to each event.
2. Applies each event to the aggregate via the matching `defapply/2` clause.
3. Runs all `definvariant/2` checks on the resulting state.
4. Returns `{:ok, %{value: aggregate, events: events}}` or `{:error, errors}`.

Command handlers in `dobro_cqrs` expect this return shape — `result.value` becomes the persisted aggregate and `result.events` are passed to the persistence layer.

### Event application (`defapply`)

Two forms:

```elixir
# Apply all fields from the event payload to the aggregate
defapply Events.OfficeCreated

# Apply only specific fields — others on the aggregate are unchanged
defapply Events.OfficeAddressChanged, [:address]

# Delete events with no state mutation (aggregate is removed by persistence)
defapply Events.CategoryDeleted, []
```

When no `defapply` clause matches, a warning is logged and the aggregate is returned unchanged. Always define `defapply` for every event your aggregate emits.

### Delete operations

Deletes emit a `*Deleted` event. The persistence layer uses the event name to resolve a `:delete` operation:

```elixir
def delete(%__MODULE__{} = template, %Delete{} = input) do
  pipeline(template, input)
  |> add_event(Events.TemplateDeleted, &with_deleted_at/2)
  |> apply_changes()
end

defapply Events.TemplateDeleted
```

### Stream names

Every aggregate defines `__stream_name__/0` for event delivery (default: `"MyApp.Office_events"`). Event handlers and projectors subscribe to this stream when using `dobro_runtime`.

---

## Domain events

Events are immutable records of something that happened. Define them in a dedicated module:

```elixir
defmodule MyApp.OfficeEvents do
  use Dobro.Domain.EventDefinition

  # Nested contracts for structured payloads
  defcontract Address do
    field :company_name, :string
    field :address_line1, :string
    field :address_line2, :string
    field :town, :string
    field :postcode, :string
    field :country, :string
  end

  defevent OfficeCreated do
    payload do
      field :name, :string
      field :abbreviation, :string
      field :phone_number, :string
      field :email_address, :string
      field :website_url, :string
      field :address, Address
    end
  end

  defevent OfficeAddressChanged do
    payload do
      field :id, :id
      field :address, Address
    end
  end

  defevent OfficeDeleted do
    payload do
      field :id, :id
      field :deleted_at, :datetime
    end
  end
end
```

### Event structure

Every event struct includes:

| Field | Purpose |
|-------|---------|
| `:payload` | Typed payload contract |
| `:message_identity` | Correlation and causation IDs (`Dobro.Domain.Messages.MessageIdentity`) |
| `:version` | Sequence number within the aggregate's event stream (set during `apply_changes/1`) |

### Creating events

Inside aggregate functions, pass an event module to `add_event/3` and the payload is built automatically from the contract input:

```elixir
|> add_event(Events.OfficeCreated)
```

For custom payloads, build the event explicitly:

```elixir
Events.CategoryMoved.new(%{
  payload: %{
    id: aggregate.id,
    original_parent_id: aggregate.parent_id,
    parent_id: input.parent_id
  }
})
```

`Event.new/1` validates the payload and auto-generates a `message_identity` when one is not supplied.

### Message identity

Events carry correlation and causation metadata for tracing chains of commands, handlers, and projections:

```elixir
%Dobro.Domain.Messages.MessageIdentity{
  id: "uuid",              # unique ID for this message
  correlation_id: "uuid",  # shared across a business transaction
  causation_id: "uuid"     # ID of the message that caused this one
}
```

The persistence layer enriches events with identity metadata before storage and PubSub delivery.

### Event payloads vs aggregate types

Event payloads often use primitive types (`:string`) even when the aggregate uses value objects (`EmailAddress`). This keeps serialised events stable and transport-friendly. Value objects are cast when events are applied back to the aggregate via `defapply`.

---

## Specifications

Specifications express preconditions that must hold **before** a command executes. Unlike invariants (checked after events are applied), specifications can read external state through ports:

```elixir
defmodule MyApp.Specifications do
  defmodule TemplateIdentifierMustBeUnique do
    use Dobro.Domain.Specification,
      ports: [MyApp.Ports.TemplateReadRepo],
      reason: :template_identifier_must_be_unique,
      description: "Template identifier must be unique"

    # Pattern match on the command contract
    def satisfied_by?(%{contract: %{identifier: id, tenant_id: tenant_id}}) do
      !template_read_repo().template_identifier_exists?(%{
        identifier: Dobro.Domain.ValueObject.value(id),
        tenant_id: tenant_id
      })
    end

    # Different contract, same specification — update with identity
    def satisfied_by?(%{
          contract: %{identifier: id, tenant_id: tenant_id},
          identity: %{id: template_id}
        }) do
      !template_read_repo().template_identifier_exists?(%{
        identifier: Dobro.Domain.ValueObject.value(id),
        tenant_id: tenant_id,
        ignore_template_ids: [template_id]
      })
    end
  end
end
```

Reference specifications in command handlers:

```elixir
handle CreateTemplate, :create,
  contract: Template.Create,
  if: [MyApp.Specifications.TemplateIdentifierMustBeUnique]
```

When a specification fails, the command handler returns an error with the configured `reason` and `description` without invoking the aggregate.

---

## Event handlers

Event handlers react to published domain events. Define a handler module and register it as a `Dobro.Ports.EventHandler` adapter:

```elixir
defmodule MyApp.OnCategoryRenamed do
  use Dobro.App.EventHandler,
    stream_name: MyApp.Category.__stream_name__()

  def handle(%MyApp.CategoryEvents.CategoryRenamed{payload: %{id: id}}) do
    MyApp.UpdatePathsJob.new(%{category_id: id}) |> Oban.insert()
    :ok
  end
end
```

Register in your adapter registry:

```elixir
defmodule MyApp.AdapterRegistry do
  use Dobro.Spec.AdapterRegistry

  register MyApp.OnCategoryRenamed
end
```

When using `dobro_runtime`, the `EventHandlerSupervisor` starts a PubSub subscriber for each registered handler at application boot. Handlers should be **idempotent** — delivery is at-least-once.

For read-model updates, use `Dobro.App.Projector` from `dobro_ecto` instead of a raw event handler.

---

## Execution context and scope

These modules support the application layer (`dobro_cqrs`) but live in the domain package because they carry domain-relevant context.

### ExecutionContext

Passed to command and query handlers:

```elixir
context = Dobro.App.ExecutionContext.new(
  auth_context: auth_context,
  tenant: tenant_context,
  selection: selection          # field selection from GraphQL, or nil
)

MyApp.OfficeCommands.Handler.execute(command, context)
```

| Field | Purpose |
|-------|---------|
| `:auth_context` | Authenticated user and permissions |
| `:tenant` | Resolved tenant for multi-tenant operations |
| `:selection` | Which fields the client requested (GraphQL) |

### Scope

Commands and queries declare scope (`:global`, `:tenant`, or `:dynamic`). `Dobro.App.Scope.setup!/2` resolves scope against the execution context at handler runtime:

```elixir
# Declared on a command module
scope :tenant, from: :context

# Resolved in the handler pipeline
scope_context = Scope.setup!(command.__scope__(), execution_context)
#=> %ScopeContext{mode: :tenant, tenant: %TenantContext{...}}
```

### ScopePolicy

`Dobro.App.ScopePolicy.validate!/2` checks that a resolved scope is compatible with a read repository's allowed scopes and tenant strategy. Called automatically by query handlers — raise a clear error when, for example, a global-scoped query hits a schema-per-tenant repo.

### Selection

`Dobro.App.Selection` represents which scalar fields and associations a client requested. GraphQL generates selections automatically; read repos in `dobro_ecto` consume them to avoid over-fetching.

---

## Testing aggregates in isolation

Aggregates have no infrastructure dependencies. Test them directly:

```elixir
test "creates an office" do
  {:ok, %{value: office, events: events}} =
    MyApp.Office.create(%MyApp.Office.Create{
      name: "Head Office",
      abbreviation: "HO",
      address: address_fixture()
    })

  assert office.name == "Head Office"
  assert office.version == 1
  assert [%MyApp.OfficeEvents.OfficeCreated{}] = events
end

test "rejects office without contact details" do
  assert {:error, _errors} =
           MyApp.Office.create(%MyApp.Office.Create{
             name: "Head Office",
             abbreviation: "HO",
             address: address_fixture()
             # no email or phone
           })
end

test "emits rename event only when name changes" do
  category = category_fixture(%{name: "Old Name"})

  {:ok, %{events: events}} =
    MyApp.Category.update(category, %MyApp.Category.Update{
      parent_id: category.parent_id,
      name: "Old Name"    # unchanged
    })

  refute Enum.any?(events, &match?(%MyApp.CategoryEvents.CategoryRenamed{}, &1))
end
```

---

## Persistence and event sourcing

The domain layer is **storage-agnostic**. Aggregates always mutate through events; how those events and resulting state are stored is configured in `dobro_ecto` and `dobro_cqrs`:

| Strategy | Domain impact | Storage |
|----------|---------------|---------|
| **Stateful persistence** | None — same aggregate functions and events | Aggregate snapshot + events in relational tables |
| **Event-sourced persistence** | None — same aggregate functions and events | Append-only event stream; state rebuilt by replay |

Both strategies implement `Dobro.App.Command.PersistenceStrategy`. Per-aggregate configuration lets you mix strategies within one application — for example, event-sourced order processing alongside stateful reference data.

The domain package never imports Ecto, PubSub, or runtime modules. Your aggregates, events, and value objects compile and test with only `dobro_schema` as a dependency.

---

## Main modules

| Module | Role |
|--------|------|
| `Dobro.Domain.Aggregate` | Aggregate root macro with event pipeline |
| `Dobro.Domain.ValueObject` | Composite value object macro |
| `Dobro.Domain.ValueObject.Singular` | Single-field value object macro |
| `Dobro.Domain.EventDefinition` | Domain event struct generation (`defevent`, `payload`) |
| `Dobro.Domain.Specification` | Precondition specifications for commands |
| `Dobro.Domain.SpecificationContext` | Context passed to `satisfied_by?/1` |
| `Dobro.Domain.Messages.MessageIdentity` | Correlation and causation IDs |
| `Dobro.Domain.Id` | UUID generation for message identities |
| `Dobro.Domain.Invariants` | `definvariant/2` macro for aggregates and value objects |
| `Dobro.App.EventHandler` | Event handler adapter macro |
| `Dobro.App.ExecutionContext` | Handler execution context |
| `Dobro.App.Scope` | Scope resolution |
| `Dobro.App.ScopePolicy` | Scope and read-repo compatibility validation |
| `Dobro.App.Selection` | Field selection for partial query results |

---

## Related packages

- [dobro_schema](https://hexdocs.pm/dobro_schema) — validation, contracts, and pipeline primitives used by aggregates
- [dobro_cqrs](https://hexdocs.pm/dobro_cqrs) — command handlers invoke aggregate functions and persist results
- [dobro_ecto](https://hexdocs.pm/dobro_ecto) — write repos persist aggregates; projectors build read models from events
- [dobro_runtime](https://hexdocs.pm/dobro_runtime) — delivers persisted events to handlers over PubSub

## License

MIT
