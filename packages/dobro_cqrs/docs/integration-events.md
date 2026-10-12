# Build plan: Integration events

**Status:** Ready to build  
**Repos:** `funeral_manager_api` (Rails), `dobro` packages, `fm` (Elixir)  
**Related:** [command-strategies.md](command-strategies.md)

Single plan for the cross-app integration event bus: Rails txn collector + aggregate DSL, Dobro/FM publisher, PG consumers, Parquet audit, timelines. MSK is a later transport only.

---

## 0. Locked decisions

| Decision | Choice |
|----------|--------|
| Domain vs integration | Separate forever. No auto-mirror. |
| Rails emission | Txn-scoped collector → `insert_all` in `before_committed!` |
| Opt-in | `track_resource_changes` (default off). No join spam. |
| Aggregates | Same DSL wave as collector: roots + explicit children with `aggregate_*` |
| Child emission | **Child event** + `aggregate_type` / `aggregate_id` (not fold-into-root-only) |
| Wire `event_type` | Dotted snake: `amount.updated`, `arrangement.created` |
| `as:` declaration | PascalCase resource label → underscored type: `"Amount"` → `amount` |
| Payload | Hybrid: update = net `changes` + full `after`; create = `after`; delete = `before` |
| Outbox ack | Append-only log. Optional `published_at` for MSK relay later. Consumers use **offset table**. |
| Transport v1 | Postgres poll by consumer name |
| Transport later | CDC/relay → MSK (not in MVP PRs) |
| Elixir write | `Dobro.App.IntegrationEvents.publish/1` from handlers only |
| Timeline writer | FM Elixir (one writer); Rails does not duplicate |
| System events | Untouched |

---

## 1. Shared contract

### 1.1 Table `shared.integration_event_outbox`

Migration ownership: **Rails** `db/shared_migrate` (FM adds matching ecto migration or relies on shared schema — pick one repo as source of truth in PR 1).

```ruby
create_table :integration_event_outbox, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.string   :event_type,         null: false  # amount.updated
  t.integer  :event_version,      null: false, default: 1
  t.string   :resource_type,      null: false  # Amount
  t.string   :resource_id,        null: false
  t.string   :operation,          null: false  # created|updated|deleted
  t.string   :producer,           null: false  # rails_api|fm
  t.string   :tenant_identifier
  t.string   :aggregate_type                 # Arrangement
  t.string   :aggregate_id
  t.uuid     :change_set_id
  t.string   :request_id
  t.jsonb    :event_payload,      null: false
  t.jsonb    :message_identity,   null: false  # {id, correlation_id, causation_id}
  t.datetime :occurred_at,        null: false, precision: 6
  t.datetime :published_at,       precision: 6 # MSK relay later; null in MVP
  t.datetime :inserted_at,        null: false, precision: 6
end

add_index :integration_event_outbox, :inserted_at
add_index :integration_event_outbox, :event_type
add_index :integration_event_outbox, [:aggregate_type, :aggregate_id, :inserted_at]
add_index :integration_event_outbox, :published_at, where: "published_at IS NULL"
```

### 1.2 Table `shared.integration_event_consumers`

```ruby
create_table :integration_event_consumers, id: false do |t|
  t.string   :name,            null: false, primary: true
  t.uuid     :last_event_id
  t.datetime :last_inserted_at, precision: 6
  t.datetime :updated_at,      null: false, precision: 6
end
```

Consumers advance after successful handling (ordered by `(inserted_at, id)`).

### 1.3 Envelope (`event_payload` jsonb)

```json
{
  "event_type": "amount.updated",
  "event_version": 1,
  "resource_type": "Amount",
  "resource_id": "42",
  "operation": "updated",
  "producer": "rails_api",
  "occurred_at": "2026-09-23T12:00:00.000000Z",
  "tenant": "acme",
  "actor": { "user_id": 99, "session_id": "…", "remote_ip": "…" },
  "aggregate_type": "Arrangement",
  "aggregate_id": "7",
  "changes": { "qty": [1, 3] },
  "before": null,
  "after": { "id": 42, "qty": 3, "other_amounts_arrangement_id": 7 },
  "message_identity": {
    "id": "…",
    "correlation_id": "…",
    "causation_id": null
  },
  "change_set_id": "…",
  "request_id": "…"
}
```

Denormalize key fields onto columns (§1.1) for indexes; full document in `event_payload`.

---

## 2. Rails build (funeral_manager_api)

### 2.1 Files to add

```
app/lib/request_context.rb                          # extend
lib/middleware/request_context.rb                   # correlation default if needed
app/lib/resource_changes/resource_identity.rb
app/lib/resource_changes/resource_change.rb
app/lib/resource_changes/change_set.rb
app/lib/resource_changes/collector.rb
app/lib/resource_changes/event_builder.rb
app/lib/resource_changes/outbox_writer.rb
app/lib/resource_changes/event_type.rb              # "Amount" + :updated → "amount.updated"
app/models/concerns/resource_change_tracking.rb
app/models/shared/integration_event_outbox.rb       # insert_all only; no callbacks
app/models/shared/integration_event_consumer.rb     # optional AR for offsets
db/shared_migrate/XXXX_create_integration_event_outbox.rb
db/shared_migrate/XXXX_create_integration_event_consumers.rb
spec/lib/resource_changes/*_spec.rb
spec/models/concerns/resource_change_tracking_spec.rb
```

### 2.2 DSL (collector + aggregates — one API)

```ruby
# Root aggregate
class Arrangements::Arrangement < ApplicationRecord
  track_resource_changes as: "Arrangement", aggregate: true
end

# Child of aggregate (timeline subject = arrangement)
class Arrangements::Service < ApplicationRecord
  track_resource_changes as: "ArrangementService",
    aggregate: { as: "Arrangement", fk: :arrangement_id }
end

# Standalone resource (no timeline parent)
class Amount < ApplicationRecord
  track_resource_changes as: "Amount"
  # optional: aggregate: { as: "Arrangement", fk: :other_amounts_arrangement_id }
  # if Amount should appear on arrangement timelines
end
```

**Rules**

- `as:` required when tracking (drives `resource_type` + `event_type`).
- `aggregate: true` → root: set `aggregate_type/id` to self.
- `aggregate: { as:, fk: }` → child: set from FK at flush; require FK present or skip event + log.
- No `children:` auto-wiring of `has_many` (avoids joins). Document intended children in a code comment or registry test that lists expected tracked classes under Arrangement.
- Never call `to_resource`.

Optional block form (validation aid only — does not auto-track assocs):

```ruby
track_resource_changes as: "Arrangement", aggregate: true do
  # Raises in test/dev if listed const is not tracked with matching aggregate:
  expect_children "Arrangements::Service", "Arrangements::Viewing"
end
```

### 2.3 Collector behaviour

1. Observe `after_create` / `after_update` / `after_destroy` (SoftDelete destroy → `deleted`).
2. Key by `[resource_type, resource_id]` inside txn uuid layer; nested savepoint stack (push/merge/discard).
3. Consolidate:

| Mutations | Net | Emit |
|-----------|-----|------|
| create (+ updates) | created | yes |
| updates only | updated | yes |
| updates + destroy | deleted | yes |
| create + destroy | — | no |

4. `before_committed!` → build envelopes → `OutboxWriter.insert_all` with `ResourceChangeTracking.without_tracking`.
5. Rollback → drop memory only.

**Invisible (document + spec):** `update_all`, `delete_all`, `update_columns`, `insert_all`, raw SQL.

### 2.4 RequestContext

Extend [`app/lib/request_context.rb`](../../../funeral_manager/funeral_manager_api/app/lib/request_context.rb):

- `correlation_id` (default `request_id`)
- `causation_id` (optional)
- `snapshot_for_integration_event` → actor (`SessionService`), tenant (`Apartment::Tenant.current`), request_id, correlation/causation

### 2.5 MVP enablement list

| Model | `as:` | `aggregate:` |
|-------|-------|--------------|
| `Arrangements::Arrangement` | Arrangement | `true` |
| `Arrangements::Service` | ArrangementService | `{ as: "Arrangement", fk: :arrangement_id }` |
| `Arrangements::Viewing` | ArrangementViewing | `{ as: "Arrangement", fk: :arrangement_id }` |
| `Amount` | Amount | `{ as: "Arrangement", fk: :other_amounts_arrangement_id }` if FK exists; else standalone |
| `Invoices::InvoiceProfile` | InvoiceProfile | `true` (or link to arrangement if that is the timeline subject — confirm FK) |
| `Invoices::Invoice` | Invoice | parent InvoiceProfile or Arrangement — **confirm FK in impl** |
| `Invoices::Item` | InvoiceItem | parent Invoice |

Exact FKs: verify in model files during implementation; adjust table above, do not invent.

Exclude permanently: `Shared::IntegrationEventOutbox`, `Shared::SystemEvent`, sessions/tokens.

### 2.6 Rails acceptance (PR A)

- [ ] Specs: consolidation matrix (8 cases)
- [ ] Nested `requires_new` rollback discards inner layer
- [ ] Outer rollback → 0 outbox rows
- [ ] Same txn → shared `change_set_id`
- [ ] Arrangement + Service update → 2 events, same `aggregate_id`
- [ ] Untracked join model → 0 events
- [ ] `update_columns` → 0 events
- [ ] Outbox `insert_all` not re-tracked
- [ ] SoftDelete path → `operation=deleted` where applicable

**Out of Rails PR A:** MSK, Parquet, Elixir, moving sync callbacks.

---

## 3. Dobro build

### 3.1 Files to add

```
packages/dobro_ecto/lib/dobro/infra/data/integration_event_outbox_schema.ex
packages/dobro_ecto/lib/dobro/infra/data/integration_outbox.ex
  # insert/1, fetch_after/2, advance_consumer/2
packages/dobro_ecto/lib/dobro/app/integration_event_codec.ex
packages/dobro_cqrs/lib/dobro/app/integration_events.ex
  # publish/1, publish!/1
packages/dobro_domain/lib/dobro/domain/integration_event.ex  # optional behaviour / helper macro
# tests mirroring domain outbox empty-list / codec tests
```

### 3.2 API

```elixir
# FM
%{}  # map matching envelope, or struct implementing type/version/payload
|> Dobro.App.IntegrationEvents.publish()
# => {:ok, id} | {:error, reason}
# insert producer: "fm", fill message_identity if missing
```

No GenServer required for publish. Optional later: `IntegrationOutboxRelay` for Elixir consumers (poll offsets) — can live in `dobro_runtime` or FM first.

### 3.3 Dobro acceptance (PR B)

- [ ] `publish/1` inserts row with `producer=fm`
- [ ] Does not touch `domain_event_outbox`
- [ ] Codec round-trip for envelope map
- [ ] Docs: this file linked from packages README (already)

---

## 4. FM Elixir build

### 4.1 Files (PR C)

```
priv/repo/migrations/XXXX_integration_event_outbox.exs   # if FM owns schema sync
lib/fm/integration/events/tenant_registered.ex           # or map inline
lib/fm/tenant_management/tenants/app/domain_event_handler.ex  # publish on TenantRegistered/Renamed
lib/fm/integration/consumers/arrangement_timeline.ex     # stub projector job
lib/fm/integration/consumers/offset_store.ex
```

### 4.2 First publishers

| Domain event | Integration `event_type` |
|--------------|--------------------------|
| `TenantRegistered` | `tenant.registered` |
| `TenantRenamed` | `tenant.renamed` |

Payload: ids + identifier + name (stable public fields only).

### 4.3 First consumer (timeline stub)

- Consumer name: `fm.arrangement_timeline`
- Filter: `aggregate_type = Arrangement` OR `event_type` like `arrangement%`
- Write: simple `arrangement_timeline_entries` table (id, arrangement_id, event_id, event_type, occurred_at, summary jsonb)
- Oban periodic or GenServer poll — MVP: Oban cron every 1s/5s claiming by offset

### 4.4 FM acceptance (PR C)

- [ ] Tenant register/rename inserts integration row
- [ ] Domain PubSub handlers still run (rename job etc.)
- [ ] Timeline consumer advances offset; idempotent on `event_id`

---

## 5. Parquet exporter (PR D — either Rails Sidekiq or FM Oban)

- Consumer name: `s3.parquet_export`
- Batch read after cursor → write Parquet under `s3://…/integration_events/dt=YYYY-MM-DD/…`
- Columns: envelope scalars + JSON strings for changes/before/after
- No MSK required

Acceptance: N rows in → N ids in file; cursor moves; re-run is idempotent.

---

## 6. MSK (PR E — later)

- Debezium or app relay on `integration_event_outbox` inserts
- Headers: `event_type`, `tenant`, `producer`, `aggregate_type`, `correlation_id`
- Set `published_at` only if using app relay (Debezium may skip)
- Consumers migrate from PG poll → Kafka at leisure

---

## 7. PR sequence (buildable order)

| PR | Repo | Delivers |
|----|------|----------|
| **A** | `funeral_manager_api` | Migrations, collector, DSL (aggregate+children), context, enablement list, specs |
| **B** | `dobro` | Schema module, `IntegrationOutbox`, `IntegrationEvents.publish`, tests, doc polish |
| **C** | `fm` | Migration sync if needed, tenant publishers, timeline consumer stub |
| **D** | `fm` or Rails | Parquet exporter |
| **E** | infra + apps | MSK |

**DB topology gate before C in prod:** confirm FM and Rails share `shared` schema physically. If not, ship twin table in FM and a copy job, or block C until shared.

---

## 8. Implementation todos (checklist)

### PR A — Rails

- [ ] Migration: `integration_event_outbox` + `integration_event_consumers`
- [ ] `RequestContext` snapshot helpers
- [ ] `ResourceIdentity` + `EventType` (`Amount`/`updated` → `amount.updated`)
- [ ] `ChangeSet` + savepoint stack + consolidation
- [ ] `Collector` + `before_committed!` duck
- [ ] `EventBuilder` (hybrid payload + aggregate_* )
- [ ] `OutboxWriter` (`insert_all`, `without_tracking`)
- [ ] `ResourceChangeTracking` (`as:`, `aggregate: true | {as:, fk:}`, `expect_children`)
- [ ] Enable MVP models (§2.5) with verified FKs
- [ ] RSpec suite (§2.6)

### PR B — Dobro

- [ ] Ecto schema + `IntegrationOutbox.insert/fetch/advance`
- [ ] `IntegrationEvents.publish/1`
- [ ] Codec + unit tests
- [ ] Update this doc status → Partially implemented

### PR C — FM

- [ ] Topology decision recorded in PR description
- [ ] TenantRegistered/Renamed → publish
- [ ] `arrangement_timeline_entries` + consumer
- [ ] Tests with sandbox / inserted fixtures

### PR D / E

- [ ] Parquet export job
- [ ] MSK wiring

---

## 9. Explicit non-goals (whole MVP through C)

- Auto domain→integration mapping in Dobro
- Emitting untracked join tables
- Replacing `after_commit` arrangement/invoice sync
- Writing Rails payloads into `domain_event_outbox`
- GraphQL dumping raw domain events
- Broker-first design

---

## 10. Done when

1. Rails request mutating Arrangement + Service + Amount (tracked) writes consolidated outbox rows with correct `aggregate_*` and one `change_set_id`.
2. Rollback writes nothing.
3. FM can `publish` a tenant integration event with the same envelope.
4. Timeline consumer can list arrangement history from outbox without join-table noise.
5. Domain event path in FM unchanged for local Oban/projectors.
