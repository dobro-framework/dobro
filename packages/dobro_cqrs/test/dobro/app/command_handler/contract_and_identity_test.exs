defmodule Dobro.App.CommandHandler.ContractAndIdentityTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.CommandHandler.Pipeline
  alias Dobro.App.ExecutionContext
  alias Dobro.Error

  defmodule Payload do
    defstruct [:name]
  end

  defmodule CreateContract do
    defstruct [:name, :author_id]

    def new(%{name: name} = attrs) do
      {:ok, %__MODULE__{name: name, author_id: Map.get(attrs, :author_id)}}
    end
  end

  defmodule Command do
    defstruct [:payload, :identity, :scope]

    def __scope__, do: {:tenant, :context}
  end

  defp ctx(tenant_id \\ 1) do
    %ExecutionContext{
      tenant: TenantContext.new(%{id: tenant_id, identifier: "acme"}),
      auth_context: %{actor: %{id: 9, type: "user"}}
    }
  end

  defp command(attrs \\ %{}) do
    %Command{
      payload: Map.get(attrs, :payload, %Payload{name: "Ada"}),
      identity: Map.get(attrs, :identity),
      scope: {:tenant, :context}
    }
  end

  describe "build_contract/2" do
    test "builds from a contract module via Module.new/1" do
      pipeline = Pipeline.pipeline(command(), ctx(), contract: CreateContract)

      assert %CreateContract{name: "Ada", author_id: nil} = pipeline.state.contract
    end

    test "builds from an arity-2 function with contract_attrs and execution_context" do
      contract_fn = fn attrs, execution_context ->
        CreateContract.new(%{
          name: attrs.name,
          author_id: execution_context.auth_context.actor.id
        })
      end

      pipeline = Pipeline.pipeline(command(), ctx(), contract: contract_fn)

      assert %CreateContract{name: "Ada", author_id: 9} = pipeline.state.contract
      assert pipeline.state.contract_attrs.name == "Ada"
      assert pipeline.config.execution_context.tenant.id == 1
    end

    test "merges errors from a failing contract function" do
      contract_fn = fn _payload, _ctx ->
        {:error, Error.new(:invalid, path: :name)}
      end

      pipeline = Pipeline.pipeline(command(), ctx(), contract: contract_fn)

      assert [%Error{reason: :invalid, path: :name}] = pipeline.errors
    end
  end

  describe "identify/2 identity_fn" do
    test "passes identity and execution_context to identity_fn" do
      identity_fn = fn identity, execution_context ->
        assert identity == %{id: 42}
        assert execution_context.auth_context.actor.id == 9
        {:ok, %{id: identity.id, actor_id: execution_context.auth_context.actor.id}}
      end

      pipeline =
        Pipeline.pipeline(command(%{identity: %{id: 42}}), ctx(), identity_fn: identity_fn)
        |> Pipeline.identify(identity_fn: identity_fn)

      assert pipeline.state.identity == %{id: 42, actor_id: 9}
    end
  end
end
