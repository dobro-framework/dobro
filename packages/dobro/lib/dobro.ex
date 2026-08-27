defmodule Dobro do
  @moduledoc """
  Dobro is a modular Elixir framework for domain-driven, CQRS-oriented applications.

  ## Installation

  With [Igniter](https://hexdocs.pm/igniter):

      mix archive.install hex igniter_new

      # Elixir-only
      mix igniter.new my_app --install dobro

      # Phoenix GraphQL API
      mix igniter.new my_api --install dobro,dobro_graphql --with phx.new \\
        --with-args="--no-html --no-live --no-assets"

  Until packages are on Hex, depend on this monorepo via git/path (see the root README).

  ## Generators

      mix dobro.gen.bc MyApp.Catalog.Products
      mix dobro.gen.aggregate MyApp.Catalog.Products.Product --fields name:string,sku:string

  Use `--tenant` on install or generators for schema-per-tenant wiring.
  """
end
