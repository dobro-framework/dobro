# Dobro Spec

Hexagonal architecture for Elixir: define **ports** (interfaces), implement **adapters**, and resolve the correct implementation at runtime through a compile-time registry.

Use this package when you want clear boundaries between domain/application code and infrastructure — with swappable implementations, straightforward test doubles, and no hard-coded module references in business logic.

## Requirements

- Elixir ~> 1.14

## Installation

```elixir
def deps do
  [{:dobro_spec, "~> 0.1.0"}]
end
```

## Configuration

```elixir
config :dobro_spec,
  otp_app: :my_app,
  adapter_registry: MyApp.AdapterRegistry
```

| Key | Description |
|-----|-------------|
| `:otp_app` | Host application used for per-port config overrides (for example Mox in tests) |
| `:adapter_registry` | Root module built with `Dobro.Spec.AdapterRegistry` |

`Dobro.Config` in this package provides shared accessors (`repo!/0`, `pubsub!/0`, etc.) used by other Dobro packages once configured in the host application.

## Concepts

| Term | Meaning |
|------|---------|
| **Port** | A behaviour module describing an interface (for example a notification service or write repository) |
| **Adapter** | A concrete implementation of a port, registered against specific criteria |
| **Registry** | Compile-time map from port + criteria → adapter module |
| **Consumer** | A module that resolves adapters at runtime via generated helper functions |

Ports are resolved with optional **criteria** — for example, selecting a write repository by aggregate module and operation (`:insert`, `:update`, `:delete`).

## Quick start

### 1. Define a port

```elixir
defmodule MyApp.Notifications do
  use Dobro.Spec.Port

  @callback deliver(map()) :: :ok | {:error, term()}
end
```

### 2. Implement an adapter

```elixir
defmodule MyApp.Notifications.Email do
  use Dobro.Spec.Adapter, port: MyApp.Notifications

  @impl true
  def deliver(%{to: to, body: body}) do
    # integrate with your mail provider
    :ok
  end
end
```

### 3. Register adapters

```elixir
defmodule MyApp.AdapterRegistry do
  use Dobro.Spec.AdapterRegistry

  register MyApp.Notifications.Email
  register MyApp.Users.Infra.UserWriteRepo
  register MyApp.Users.Infra.UserReadRepo
end
```

### 4. Resolve at runtime

```elixir
MyApp.Notifications.adapter().deliver(%{to: "user@example.com", body: "Hello"})
```

## Criteria-based resolution

When an adapter serves multiple contexts, register it with criteria so the registry can pick the right module:

```elixir
use Dobro.Spec.Adapter,
  port: Dobro.Infra.Data.WriteRepo.Port,
  for: [aggregate: MyApp.User, operations: [:insert, :update, :delete, :get]]
```

Consumers declare which ports they need:

```elixir
defmodule MyApp.Users.App.UserRegistration do
  use Dobro.Spec.Consumer, ports: [notifications: MyApp.Notifications.Port]

  def send_welcome(user) do
    notifications().deliver(%{to: user.email, template: :welcome})
  end
end
```

## Per-environment adapter overrides

In test, override a port adapter via application config without changing code:

```elixir
# config/test.exs
config :my_app, MyApp.Notifications, adapter: MyApp.Notifications.Mock
```

The port's `adapter/0` function checks `Application.get_env(:my_app, MyApp.Notifications, [])` first, then falls back to the registry.

## Testing with Mox

```elixir
defmodule MyApp.NotificationsTest do
  use ExUnit.Case
  use Dobro.Spec.Mocks   # generates MyApp.Notifications.Mock

  setup do
    Dobro.Spec.Mocks.register_all()
    :ok
  end

  test "sends a notification" do
    expect(MyApp.Notifications.Mock, :deliver, fn _ -> :ok end)
    MyApp.Notifications.adapter().deliver(%{to: "a@b.com", body: "Hi"})
  end
end
```

## Main modules

| Module | Role |
|--------|------|
| `Dobro.Spec.Port` | Declare a port and resolve adapters |
| `Dobro.Spec.Adapter` | Mark a module as implementing a port |
| `Dobro.Spec.AdapterRegistry` | Compile-time adapter registry |
| `Dobro.Spec.Consumer` | Inject port accessor functions into a module |
| `Dobro.Spec.Mocks` | Generate Mox mocks for registered ports |
| `Dobro.Config` | Shared configuration accessors for all Dobro packages |

## Related packages

- [dobro_schema](https://hexdocs.pm/dobro_schema) — validation and contracts built on the same error model
- [dobro_ecto](https://hexdocs.pm/dobro_ecto) — read/write repositories registered as port adapters
- [dobro_cqrs](https://hexdocs.pm/dobro_cqrs) — command handlers resolve write repos through ports

## License

MIT
