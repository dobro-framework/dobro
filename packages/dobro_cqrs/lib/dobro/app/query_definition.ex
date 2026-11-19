defmodule Dobro.App.QueryDefinition do
  @moduledoc """
  Macros for defining **application-layer** queries.

  Use `query/2` to declare a use-case query struct (its payload). A query runs
  in the request's context: a tenant's, or global with no tenant.
  Use `query_handler/3` to wire queries to read repo functions.

  This is **not** where Ecto/SQL queries are defined — use `defquery` in a
  `Dobro.Infra.Data.ReadRepo` module ([dobro_ecto](https://hexdocs.pm/dobro_ecto)).

  ## Example

      query ListCategories do
        payload do
          field :query, Dobro.App.Types.Query
        end
      end

      query_handler Handler, repo: CategoryReadRepo do
        handle ListCategories, :list_categories
      end

  See the [package README](readme.html) for the full application vs infrastructure query guide.
  """
  defmacro __using__(_opts \\ []) do
    quote do
      import Dobro.App.QueryDefinition

      use Dobro.App.Definition
    end
  end

  defmacro description(text) when is_binary(text) do
    quote do
      Module.put_attribute(__MODULE__, :description, unquote(text))
    end
  end

  defmacro query(module_name, do: block) do
    quote do
      defmodule unquote(module_name) do
        use Dobro.App.Query
        use Dobro.App.Definition
        import Dobro.App.QueryDefinition, only: [description: 1]

        unquote(block)
      end
    end
  end

  defmacro query(module_name) do
    quote do
      defmodule unquote(module_name) do
        use Dobro.App.Query
        use Dobro.App.Definition

        schema(do: nil)
      end
    end
  end

  defmacro query_handler(module_name, opts \\ [], do: block) do
    quote do
      defmodule unquote(module_name) do
        use Dobro.App.QueryHandler, unquote(opts)
        unquote(block)
      end
    end
  end
end
