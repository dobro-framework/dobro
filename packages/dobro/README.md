# Dobro

Meta package for the [Dobro](https://github.com/dobro-framework/dobro) framework: Igniter installer and generators.

## Install

```bash
mix igniter.new my_app --install dobro
# or in an existing project:
mix igniter.install dobro
# schema-per-tenant:
mix igniter.install dobro --tenant
```

## Generators

```bash
mix dobro.gen.bc MyApp.Catalog.Products
mix dobro.gen.aggregate MyApp.Catalog.Products.Product --fields name:string,sku:string
```

See the [monorepo README](https://github.com/dobro-framework/dobro) for full documentation.
