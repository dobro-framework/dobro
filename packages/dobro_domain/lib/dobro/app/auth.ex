defmodule Dobro.App.Auth do
  @moduledoc """
  API Auth
  """

  defmodule SystemActor do
    @moduledoc """
    System Actor represents the system as an actor
    """
    use TypedStruct

    typedstruct do
      field :type, :system, default: :system
    end

    def new, do: %__MODULE__{}
    def new(%__MODULE__{} = actor), do: actor

    def new(type) when is_atom(type) do
      %__MODULE__{type: type}
    end
  end

  defmodule AuthContext do
    @moduledoc """
    Auth Context holds authentication information
    """
    use TypedStruct

    typedstruct do
      field :actor, map() | nil, default: nil
    end

    def new(%__MODULE__{} = context), do: context

    def new(attrs) do
      struct(__MODULE__, attrs)
    end

    def fetch(struct, key) do
      Map.fetch(Map.from_struct(struct), key)
    end
  end

  defmodule TenantContext do
    @moduledoc """
    Minimal struct that holds tenant information.

    Tenants may be resolved with only an `:id` (e.g. `scope :tenant, from: :payload`),
    only an `:identifier` (e.g. host/JWT based context), or both (e.g. auth plugs that
    look up the tenant record). Runtime partitions (aggregate actors, event streams)
    always key by immutable `:id` — call `Dobro.Tenant.normalize/1` first when the
    context may be identifier-only.
    """
    use TypedStruct

    typedstruct do
      field :id, integer() | nil, default: nil
      field :identifier, String.t() | nil, default: nil
    end

    def new(%__MODULE__{} = context), do: context

    def new(attrs) do
      struct(__MODULE__, attrs)
    end

    def fetch(struct, key) do
      Map.fetch(Map.from_struct(struct), key)
    end

    @doc """
    Stable partition key for tenant-scoped runtime resources (aggregate actors, event
    streams, etc.).

    Always keys by immutable tenant `:id`. Identifier must never be used — it can be
    renamed while actors are running. Identifier-only contexts must be normalized via
    `Dobro.Tenant.normalize/1` first.
    """
    @spec partition_key(t() | nil) :: String.t()
    def partition_key(nil), do: "global"

    def partition_key(%__MODULE__{id: id}) when not is_nil(id), do: "id:#{id}"

    def partition_key(%__MODULE__{} = tenant) do
      raise ArgumentError,
            "TenantContext.partition_key/1 requires :id, got: #{inspect(tenant)}. " <>
              "Normalize via Dobro.Tenant.normalize/1 when only :identifier is available."
    end
  end
end
