defmodule Dobro.App.Scope do
  @moduledoc """
  A request's scope: global (no tenant) or one tenant, taken from the
  `ExecutionContext` (for HTTP, the request's tenant). A read repo declares the
  scopes it serves (`scopes: [:global, :tenant]`), checked by
  `Dobro.App.ScopePolicy`.
  """

  defmodule Error do
    @moduledoc "Raised when a request's scope cannot be served (e.g. no tenant context)."
    defexception [:message]
  end
end
