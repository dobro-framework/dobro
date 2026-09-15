# RFC: Command execution, persistence, and event delivery strategies

**Status:** Accepted (Phases 1–5 implemented)  
**Package:** `dobro_cqrs` (+ `dobro_runtime`, `dobro_ecto` for implementations)  
**Replaces:** `CommandExecutor`, `CommandPersistence`, and coupled runtime adapters

---

## Summary

Command handling currently mixes three independent concerns into two behaviours:

1. **How** the aggregate function runs (in-process vs actor)
2. **How** aggregate state and events are stored
3. **How** domain events reach subscribers

This RFC splits them into three strategy types with shorthand configuration, layered overrides, and a shared orchestrator — matching existing Dobro conventions (`DeleteStrategy`, `tenant_strategy`).

---

## Motivation

The pre-package refactor had clear separation in behaviour but unclear naming. The initial package split introduced `CommandExecutor` and `CommandPersistence`, which:

- Coupled PubSub broadcast to persistence (`Runtime.CommandPersistence`)
- Coupled actor routing to persistence configuration at the app level
- Used names that don't match the rest of the codebase (`*Strategy`)

Goals:

- Align naming with `DeleteStrategy`, `tenant_strategy`, etc.
- Allow any combination of execution, persistence, and delivery (e.g. `:inline` + `:pubsub`, `:actor` + `:outbox`)
- Support app defaults with per-handler and per-handle overrides
- Preserve actor-internal persistence (avoid load/mutate/write races)
- Leave room for event-sourced persistence and transactional outbox

---

## Three strategy types

### 1. Execution strategy

Controls **how and where** the aggregate domain function runs.

| Shorthand | Module | Description |
|-----------|--------|-------------|
| `:inline` | `ExecutionStrategy.Inline` | Always run the aggregate in the caller's process. No actors. |
| `:actor_when_identified` | `ExecutionStrategy.ActorWhenIdentified` | **Default.** `:inline` when the command has no `identity`; `AggregateActor` when it does. |
| `:actor` | `ExecutionStrategy.Actor` | Always route through `AggregateActor`. Command **must** declare `identity` (compile-time check). |

**Naming note:** `:inline` aligns with Oban's test mode terminology. `:actor_when_identified` makes the conditional explicit.

**Package placement:**

- `ExecutionStrategy` behaviour + `Inline` + `ActorWhenIdentified` → `dobro_cqrs`
- `ExecutionStrategy.Actor` → `dobro_runtime` (requires OTP supervision tree)

### 2. Persistence strategy

Controls **how** aggregate state and domain events are stored after a successful domain invocation.

| Shorthand | Module | Description |
|-----------|--------|-------------|
| `:stateful` | `PersistenceStrategy.Stateful` | **Default.** Write snapshot + events through WriteRepo ports. Optimistic concurrency uses the aggregate `version` field (`:concurrent_modification` on conflict). |
| `:event_sourced` | `PersistenceStrategy.EventSourced` | Append to event store; state derived by replay. Append uses event `version` as `event_number`; unique `(stream_name, event_number)` violations map to `:concurrent_modification`. |

Persistence strategies do **not** publish events to subscribers.

On multi-node hosts, pair actor execution with Dobro's clustering config (`actor_lock` / `actor_registry`) so each aggregate identity has a single in-memory actor cluster-wide. See [`dobro_runtime` Clustering / multi-node](../../dobro_runtime/README.md#clustering--multi-node).

Shared write logic (enrich events, resolve insert/update/delete, call WriteRepo) lives in a helper module — not a strategy itself:

- `PersistenceStrategy.Write` → `Dobro.Infra.Data.WriteRepo.Persist` + `Dobro.App.Command.EventEnrichment`

### 3. Event delivery strategy

Controls **how** successfully persisted domain events reach downstream consumers.

| Shorthand | Module | Description |
|-----------|--------|-------------|
| `:none` | `EventDeliveryStrategy.None` | **Default.** No delivery. |
| `:pubsub` | `EventDeliveryStrategy.PubSub` | Broadcast on aggregate stream after commit. |
| `:outbox` | `EventDeliveryStrategy.Outbox` | Insert outbox rows in the same transaction; async relay publishes later. |

Delivery is independent of execution: `:inline` + `:pubsub` and `:actor` + `:none` are both valid.

**Package placement:**

- `EventDeliveryStrategy` behaviour + `None` → `dobro_cqrs`
- `EventDeliveryStrategy.PubSub` → `dobro_runtime`
- `EventDeliveryStrategy.Outbox` + relay → `dobro_runtime` (optional) + schema in `dobro_ecto`

---

## Strategy resolution

Resolution order (most specific wins):

```
1. handle/3 options          (per command)
2. command_handler options   (per handler module)
3. config :dobro_cqrs        (application)
4. hardcoded defaults
```

### Hardcoded defaults

```elixir
execution_strategy: :actor_when_identified
persistence_strategy: :stateful
event_delivery_strategy: :none
```

### Application configuration (FM target)

```elixir
config :dobro_cqrs,
  execution_strategy: :actor_when_identified,
  persistence_strategy: :stateful,
  event_delivery_strategy: :pubsub

config :dobro_runtime,
  pubsub: Fm.PubSub
```

### Per-handler override

```elixir
command_handler Handler,
  aggregate: Category,
  execution_strategy: :actor,
  event_delivery_strategy: :none do
  handle UpdateCategory, :update, contract: Category.Update
end
```

### Per-handle override

```elixir
handle CreateCategory, :create,
  contract: Category.Create,
  event_delivery_strategy: :none
```

### Resolver API

```elixir
Dobro.App.Command.Strategy.resolve(pipeline, handler_opts, handle_opts)
#=> %{
#     execution: ExecutionStrategy.ActorWhenIdentified,
#     persistence: PersistenceStrategy.Stateful,
#     event_delivery: EventDeliveryStrategy.PubSub
#   }
```

Shorthand atoms are normalised via `Strategy.resolve/2` modules (same pattern as `DeleteStrategy.resolve/1`):

```elixir
ExecutionStrategy.resolve(:inline)              #=> {ExecutionStrategy.Inline, []}
EventDeliveryStrategy.resolve(:pubsub)          #=> {EventDeliveryStrategy.PubSub, []}
```

---

## Orchestration

### Inline path (`:inline`, or `:actor_when_identified` without identity)

Handled by the command handler pipeline:

```
specify → identify → build contract
  → ExecutionStrategy.Inline.execute(pipeline, call_fn, aggregate, opts)
      → invoke aggregate in-process
      → {:ok, aggregate, events} on pipeline state
  → Command.Commit.run(strategies, pipeline)
      → Repo.transaction:
          PersistenceStrategy.persist(uow, events, tenant, message_identity)
          EventDeliveryStrategy.stage(events, ...)   # :outbox only; inside txn
      → EventDeliveryStrategy.deliver(events, ...)   # :pubsub; after commit
  → finalize
```

### Actor path (`:actor`, or `:actor_when_identified` with identity)

Handler delegates to `AggregateActor`. **Persistence and delivery run inside the actor** (preserving pre-package behaviour and avoiding races):

```
specify → identify → build contract
  → ExecutionStrategy.Actor.execute(...)  or ActorWhenIdentified → actor branch
      → AggregateSupervisor.ensure_started
      → AggregateActor.execute(pid, call_fn, contract, message_identity)
          → load aggregate (write repo)
          → apply aggregate function
          → Command.Commit.run(strategies, ...)   # same helper as inline path
          → reply {:ok, result} | {:error, error}
  → merge result into handler pipeline
  → finalize
```

The actor holds the GenServer lock from load through persist (and delivery staging), so concurrent commands against the same `(aggregate_module, tenant, identity)` remain serialised.

### Shared commit helper

`Dobro.App.Command.Commit` centralises transaction boundaries and strategy invocation for both paths.

Boundaries are derived from two signals:

1. **Persist** — `PersistenceStrategy.transactional_persist?/4` (stateful delegates to WriteRepo `transactional?/0`; remote/HTTP adapters return `false`)
2. **Stage** — `EventDeliveryStrategy.transactional_stage?/0` (`:outbox` → true; `:pubsub` / `:none` → false)

| Persist DB? | Stage DB? | Behaviour |
|-------------|-----------|-----------|
| yes | yes | One transaction around persist + stage (classic outbox) |
| no | yes | Persist outside; transaction only around stage |
| \* | no | No Commit-level transaction (avoids holding a pool connection across HTTP) |

```elixir
@spec run(Strategy.t(), unit_of_work, events, tenant, message_identity, aggregate) ::
        {:ok, unit_of_work, events} | {:error, term()}
```

Remote WriteRepos must declare `transactional?/0` as `false` (or `use WriteRepo, transactional: false`).

---

## Behaviour contracts

### ExecutionStrategy

```elixir
@callback execute(pipeline, call_fn, aggregate_module, opts) :: pipeline
```

Responsible for getting from validated input to `{aggregate, events}` on pipeline state. Does **not** persist.

### PersistenceStrategy

```elixir
@callback persist(unit_of_work, events, tenant, message_identity) ::
            {:ok, unit_of_work, events} | {:error, term()}
```

Called by `Dobro.App.Command.Commit`. Whether this runs inside a DB transaction
depends on `transactional_persist?/4` and the delivery strategy's
`transactional_stage?/0` — not always.

### EventDeliveryStrategy

Two-phase where needed:

```elixir
@callback stage(events, context) :: :ok | {:error, term()}
# Called inside the persistence transaction.
# :none and :pubsub → no-op
# :outbox → INSERT into outbox table

@callback deliver(events, context) :: :ok | {:error, term()}
# Called after successful transaction commit.
# :none and :outbox → no-op (outbox relay handles delivery)
# :pubsub → PubSub.broadcast per event
```

---

## Transactional outbox (`:outbox`)

### Feasibility

High. The stack already has:

- Ecto transactions on the inline path
- Persist-inside-actor on the actor path
- Idempotent event handlers and projection versioning
- Oban in FM for background work

### Flow

**Phase 1 — inside transaction** (via `stage/2`):

```elixir
# domain_event_outbox table
# id, stream_name, event_payload, message_identity, inserted_at, processed_at
EventDeliveryStrategy.Outbox.stage(events, %{aggregate: aggregate, tenant: tenant})
```

**Phase 2 — async relay** (Oban worker or dedicated GenServer):

```elixir
EventDeliveryStrategy.Outbox.relay(batch_size: 100)
# SELECT ... FOR UPDATE SKIP LOCKED
# PubSub.broadcast(stream, {:event, event})
# UPDATE processed_at
```

### Why a delivery strategy, not persistence

Aggregate storage stays `:stateful`. Outbox records are **delivery intent**, written atomically with the business write so a crash after commit never loses an event that was durably committed.

### Relay options

| Approach | Pros | Cons |
|----------|------|------|
| Oban cron worker | Already in FM; retries; visibility | Poll latency |
| GenServer + `:timer` | Simple; lives in runtime supervision | Less operational tooling |
| PostgreSQL `LISTEN/NOTIFY` | Low latency | More wiring |

Recommendation: Oban worker in host app initially; optional `Dobro.Runtime.OutboxRelay` in `dobro_runtime` later.

### Ordering

Relay should publish in `inserted_at` order per `stream_name` when ordering matters. Consumers remain idempotent (at-least-once).

---

## Compile-time enforcement

### `:actor` execution strategy

When resolved execution strategy is `:actor`:

| Check | When | Error |
|-------|------|-------|
| Command has `identity` block | `@before_compile` on handler, or `handle` macro | `"command #{module} requires identity for execution_strategy: :actor"` |

Applies to:

- Handler-level `execution_strategy: :actor`
- App-level default `:actor`
- Per-handle `execution_strategy: :actor`

Does **not** require identity for `:inline` or `:actor_when_identified`.

### Runtime guard (belt and suspenders)

If `:actor` is resolved but identity is nil at runtime (misconfiguration), return `:execution_strategy_requires_identity` — same pattern as today's `:runtime_required`.

---

## Module layout

```
dobro_cqrs/
  lib/dobro/app/command/
    strategy.ex                          # resolve/3 for all three
    commit.ex                            # shared transaction + delivery orchestration
    execution_strategy.ex                # behaviour + resolve/1
    execution_strategy/
      inline.ex
      actor_when_identified.ex
    persistence_strategy.ex
    persistence_strategy/
      stateful.ex
      event_sourced.ex
    event_enrichment.ex
    event_delivery_strategy.ex
    event_delivery_strategy/
      none.ex

dobro_ecto/
  lib/dobro/infra/data/
    write_repo/
      persist.ex                          # stateful aggregate snapshot writes
      operation.ex                        # :insert | :update | :delete resolution
    domain_event_outbox_schema.ex
  lib/dobro/app/
    event_store.ex

dobro_runtime/
  lib/dobro/runtime/command/
    execution_strategy/
      actor.ex
    event_delivery_strategy/
      pubsub.ex
      outbox.ex                           # stage/2 in transaction
  lib/dobro/runtime/
    outbox_relay.ex                       # optional supervised GenServer
```

---

## Configuration keys

| Key | Type | Default |
|-----|------|---------|
| `:execution_strategy` | atom or `{module, opts}` | `:actor_when_identified` |
| `:persistence_strategy` | atom or `{module, opts}` | `:stateful` |
| `:event_delivery_strategy` | atom or `{module, opts}` | `:none` |

Handler and handle options use the same keys.

### Removed modules (Phase 5 complete)

The following were removed in Phase 5. Use the replacements below:

| Removed | Replacement |
|---------|-------------|
| `config :dobro_cqrs, :command_executor` | `:execution_strategy` |
| `config :dobro_cqrs, :command_persistence` | `:persistence_strategy` + `:event_delivery_strategy` |
| `Dobro.App.CommandExecutor` | `Dobro.App.Command.ExecutionStrategy` |
| `Dobro.App.CommandPersistence` | `PersistenceStrategy` + `EventDeliveryStrategy` |
| `Dobro.App.CommandExecutor.Sync` | `ExecutionStrategy.Inline` |
| `Dobro.Runtime.CommandExecutor` | `ExecutionStrategy.Actor` + `ActorWhenIdentified` actor branch |
| `Dobro.App.CommandPersistence.Sync` | `PersistenceStrategy.Stateful` + `EventDeliveryStrategy.None` |
| `Dobro.Runtime.CommandPersistence` | `PersistenceStrategy.Stateful` + `EventDeliveryStrategy.PubSub` |
| `Dobro.Cqrs.Config` `command_executor/0` | `Dobro.Cqrs.Config.execution_strategy/0` (etc.) |
| `Dobro.App.CommandPersistence.Write` | `WriteRepo.Persist` + `EventEnrichment` |

---

## Strategy combination matrix

| execution | persistence | event_delivery | Typical use |
|-----------|-------------|----------------|-------------|
| `:inline` | `:stateful` | `:none` | Minimal stack; tests; scripts |
| `:inline` | `:stateful` | `:pubsub` | Creates without actors but with live handlers |
| `:actor_when_identified` | `:stateful` | `:pubsub` | **FM production default** |
| `:actor` | `:stateful` | `:pubsub` | All commands identified; max consistency |
| `:inline` | `:stateful` | `:outbox` | Reliable delivery without actors |
| `:actor_when_identified` | `:stateful` | `:outbox` | Production with guaranteed delivery |
| *any* | `:event_sourced` | `:pubsub` / `:outbox` | Event-sourced aggregates with PubSub or outbox delivery |

---

## Migration plan (completed)

All phases below are implemented.

### Phase 1 — Introduce without behaviour change ✓

1. Add strategy behaviours, resolver, defaults, and `Command.Commit`
2. Implement `Inline`, `ActorWhenIdentified`, `Stateful`, `None`, `PubSub` as wrappers around current logic
3. Wire handler helpers and `AggregateActor` through `Command.Commit`
4. FM config uses new strategy keys
5. All existing tests pass

### Phase 2 — Macros and overrides ✓

1. Add `execution_strategy`, `persistence_strategy`, `event_delivery_strategy` to `command_handler` and `handle` macros
2. Compile-time check for `:actor` + missing identity
3. Document override examples

### Phase 3 — Outbox ✓

1. Outbox schema in `dobro_ecto`
2. `EventDeliveryStrategy.Outbox` with `stage/2`
3. `Dobro.Runtime.OutboxRelay` supervised GenServer
4. FM can switch `event_delivery_strategy: :outbox` when ready

### Phase 4 — Event sourcing ✓

1. `PersistenceStrategy.EventSourced` implementation
2. Per-aggregate strategy override via `use Dobro.Domain.Aggregate, persistence_strategy: :event_sourced`

### Phase 5 — Cleanup ✓

1. Remove deprecated modules and config keys
2. Update all READMEs and HexDocs

---

## Resolved decisions

1. **Per-aggregate persistence override** — Deferred until Phase 4; implemented on `Dobro.Domain.Aggregate` via `persistence_strategy:` option.

2. **Outbox relay ownership** — Supervised `Dobro.Runtime.OutboxRelay` in `dobro_runtime` (no hard Oban dependency).

3. **PubSub after commit in actor** — `deliver/2` runs after transaction commits but before GenServer replies. Outbox `stage/2` inside txn; `deliver/2` no-op for outbox.

4. **`Dobro.Runtime.Persistence`** — Internal load helper for aggregate actors; not part of the public strategy API.

---

## References

- Current implementation: `CommandHandler.Helpers`, `AggregateActor`, `WriteRepo.Persist`, `EventEnrichment`
- Analogous pattern: `Dobro.Infra.Data.WriteRepo.DeleteStrategy`
- Pre-package behaviour: persist inside actor for identified commands
