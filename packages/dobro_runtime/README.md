# Dobro Runtime

OTP infrastructure for executing commands against aggregate instances, persisting changes, and delivering domain events to subscribers.

This package provides **concurrency control** for identified aggregates and **event delivery** over PubSub. It complements `dobro_cqrs` — which defines what commands do — with process-based execution and asynchronous event fan-out.

## Requirements

- Elixir ~> 1.14
- Phoenix PubSub ~> 2.1
- [dobro_cqrs](https://hexdocs.pm/dobro_cqrs), [dobro_ecto](https://hexdocs.pm/dobro_ecto), and their dependencies ~> 0.1

## Installation

```elixir
def deps do
  [
    {:dobro_runtime, "~> 0.1.0"},
    {:dobro_cqrs, "~> 0.1.0"},
    {:dobro_ecto, "~> 0.1.0"}
  ]
end
```

## Configuration

```elixir
config :dobro_runtime,
  pubsub: MyApp.PubSub,
  outbox_relay: [enabled: false, batch_size: 100, poll_interval_ms: 1_000]

config :dobro_cqrs,
  execution_strategy: :actor_when_identified,
  persistence_strategy: :stateful,
  event_delivery_strategy: :pubsub
```

Set `event_delivery_strategy: :outbox` and `outbox_relay: [enabled: true, ...]` for transactional outbox delivery via `Dobro.Runtime.OutboxRelay`.

## Supervision tree

Add these children to your application supervisor:

```elixir
children = [
  {Registry, keys: :unique, name: Dobro.Runtime.Registry},
  {Dobro.Runtime.AggregateSupervisor, name: Dobro.Runtime.AggregateSupervisor},
  {Dobro.Runtime.EventHandlerSupervisor, name: Dobro.Runtime.EventHandlerSupervisor}
]
```

| Process | Role |
|---------|------|
| `Registry` | Lookup aggregate actors by `{module, tenant, identity}` |
| `AggregateSupervisor` | DynamicSupervisor that starts aggregate GenServers on demand |
| `EventHandlerSupervisor` | Starts one PubSub subscriber per registered event handler at boot |

## How it works

### Identified commands (aggregate actors)

When a command handler targets an aggregate with a resolved identity:

1. **`AggregateSupervisor`** starts or finds a GenServer for `(aggregate_module, tenant, identity)`.
2. The **`AggregateActor`** serialises concurrent requests, loads the aggregate, runs the domain function, and commits via `Dobro.App.Command.Commit`.
3. Configured **persistence** and **event delivery** strategies run inside the actor (stateful write, event store append, PubSub broadcast, or outbox staging).
4. **`EventHandlerActor`** subscribers receive events and delegate to registered handler modules.

This ensures that two concurrent updates to the same aggregate instance are processed sequentially, preventing lost updates.

### Stateless commands (inline fallback)

Commands without an identity use `ExecutionStrategy.Inline` — the same in-process path used when runtime is not configured. No actor is started.

### Event delivery flow (PubSub)

```
AggregateActor
  → Command.Commit
  → PersistenceStrategy (stateful or event-sourced)
  → EventDeliveryStrategy (pubsub or outbox)
  → PubSub.broadcast(stream, {:event, event})   # pubsub, or via OutboxRelay
  → EventHandlerActor (per handler)
  → handler.handle(event)
```

Stream names come from `AggregateModule.__stream_name__/0`. Event handlers declare which stream they subscribe to via `Dobro.App.EventHandler`.

## Event handlers

Define a handler module and register it as a `Dobro.Ports.EventHandler` adapter:

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

Register the handler in your adapter registry. The `EventHandlerSupervisor` starts a dedicated subscriber GenServer for each registered handler when the application boots.

Handlers should be **idempotent** — PubSub delivery is at-least-once. Projectors track position in a `projection_versions` table for the same reason.

## Persistence integration

Runtime delegates storage to configured **persistence strategies** (`Stateful`, `EventSourced` in `dobro_cqrs`; backed by `WriteRepo.Persist` and `EventStore` in `dobro_ecto`) and delivery to **event delivery strategies** (`PubSub`, `Outbox`). `Dobro.App.Command.Commit` orchestrates both inside aggregate actors and inline command paths.

### Storage strategies

| Strategy | Runtime role |
|----------|--------------|
| **Stateful persistence** | Writes aggregate snapshot + events to relational tables |
| **Event-sourced persistence** | Appends events to `event_store.domain_events`; state rebuilt by replay on load |

The runtime layer does not dictate storage strategy — it orchestrates execution and delivery after the configured persistence module completes.

## Runtime strategy modules

| Module | Role |
|--------|------|
| `Dobro.Runtime.Command.ExecutionStrategy.Actor` | Actor-based execution for identified commands |
| `Dobro.Runtime.Command.EventDeliveryStrategy.PubSub` | Post-commit PubSub broadcast |
| `Dobro.Runtime.Command.EventDeliveryStrategy.Outbox` | Transactional outbox staging |
| `Dobro.Runtime.OutboxRelay` | Polls outbox and publishes to PubSub |
| `Dobro.Runtime.Persistence` | Aggregate load (WriteRepo or event replay) |

## Main modules

| Module | Role |
|--------|------|
| `Dobro.Runtime.AggregateActor` | GenServer per aggregate instance |
| `Dobro.Runtime.AggregateSupervisor` | Dynamic supervisor for actors |
| `Dobro.Runtime.Persistence` | Load aggregates for actors |
| `Dobro.Runtime.OutboxRelay` | Supervised outbox polling GenServer |
| `Dobro.Runtime.EventHandlerActor` | PubSub subscriber for a handler module |
| `Dobro.Runtime.EventHandlerSupervisor` | Supervisor for event handler subscribers |

## Related packages

- [dobro_cqrs](https://hexdocs.pm/dobro_cqrs) — defines commands, handlers, and APIs consumed by runtime
- [dobro_ecto](https://hexdocs.pm/dobro_ecto) — write repos and shared persistence logic
- [dobro_domain](https://hexdocs.pm/dobro_domain) — event handler macro and domain events

## License

MIT
