# Dobro

Dobro is a modular Elixir framework for building domain-driven, CQRS-oriented applications with hexagonal architecture.

This monorepo hosts the Hex packages (path deps locally; git/Hex for consumers).

## Packages

| Package | Purpose |
|---------|---------|
| [`dobro`](packages/dobro/) | Meta package — Igniter installer + generators |
| [`dobro_spec`](packages/dobro_spec/) | Ports, adapters, adapter registries |
| [`dobro_schema`](packages/dobro_schema/) | Typed schemas, contracts, validation |
| [`dobro_domain`](packages/dobro_domain/) | Aggregates, events, value objects |
| [`dobro_ecto`](packages/dobro_ecto/) | Read/write repos, `defquery`, projections |
| [`dobro_cqrs`](packages/dobro_cqrs/) | Commands, queries, handlers, public APIs |
| [`dobro_runtime`](packages/dobro_runtime/) | Aggregate actors, event delivery |
| [`dobro_graphql`](packages/dobro_graphql/) | Absinthe generation from Dobro APIs (**optional**) |
| [`dobro_ai`](packages/dobro_ai/) | AI sessions / tool calling (**optional**) |

## Quick start (Igniter)

```bash
mix archive.install hex igniter_new
mix archive.install hex phx_new   # only if you want Phoenix
```

### Elixir-only

```bash
mix igniter.new my_app --install dobro
```

### Phoenix GraphQL API

```bash
mix igniter.new my_api \
  --install dobro,dobro_graphql \
  --with phx.new \
  --with-args="--no-html --no-live --no-assets"
```

### Schema-per-tenant

```bash
mix igniter.install dobro --tenant
```

### Generators

```bash
mix dobro.gen.bc MyApp.Catalog.Products
mix dobro.gen.aggregate MyApp.Catalog.Products.Product --fields name:string,sku:string
# with tenancy:
mix dobro.gen.aggregate MyApp.Catalog.Products.Product --fields name:string --tenant
```

## Using this repo before Hex

Packages are not published to Hex yet. Prefer a **full clone** and path deps (sibling path resolution works in the monorepo):

```elixir
# mix.exs — clone github.com/dobro-framework/dobro next to your app
dobro = Path.expand("../dobro/packages", __DIR__)

defp deps do
  [
    {:dobro, path: Path.join(dobro, "dobro")},
    {:igniter, "~> 0.6", only: [:dev, :test]}
  ]
end
```

Then:

```bash
mix deps.get
mix dobro.install
# or: mix igniter.install dobro   # once the package is on Hex
```

Git sparse deps also work: each package’s `mix.exs` falls back to

`{:pkg, github: "dobro-framework/dobro", sparse: "packages/pkg", branch: "main"}`

when the sibling path is missing (so `{:dobro, github: "dobro-framework/dobro", sparse: "packages/dobro", branch: "main"}` pulls the core stack).

## Development

```bash
mix test          # all packages
mix dobro.test    # alias
```

From a single package:

```bash
cd packages/dobro_cqrs && mix test
```

## Publishing to Hex (later)

Publish in dependency order: `dobro_spec` → `dobro_schema` → `dobro_domain` → `dobro_ecto` → `dobro_cqrs` → `dobro_runtime` → `dobro` → `dobro_graphql` / `dobro_ai`.

Before publishing, replace path/git fallbacks in each `mix.exs` with version constraints (e.g. `{:dobro_schema, "~> 0.1.0"}`).

## License

MIT
