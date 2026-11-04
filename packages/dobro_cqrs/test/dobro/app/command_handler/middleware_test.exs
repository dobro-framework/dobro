defmodule Dobro.App.CommandHandler.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.Command.Middleware
  alias Dobro.App.CommandHandler.Pipeline
  alias Dobro.App.ExecutionContext
  alias Dobro.Error

  defmodule Payload do
    defstruct [:name]
  end

  defmodule CreateContract do
    defstruct [:name, :author_id, :tag]

    def new(%{} = attrs) do
      {:ok,
       %__MODULE__{
         name: Map.get(attrs, :name),
         author_id: Map.get(attrs, :author_id),
         tag: Map.get(attrs, :tag)
       }}
    end
  end

  defmodule Command do
    defstruct [:payload, :identity, :scope]

    def __scope__, do: {:tenant, :context}
  end

  defmodule InjectAuthorId do
    use Middleware

    @impl true
    def call(pipeline) do
      attrs = Map.put(pipeline.state.contract_attrs, :author_id, 99)
      put_in(pipeline.state.contract_attrs, attrs)
    end
  end

  defmodule TagAfterContract do
    use Middleware

    @impl true
    def phase, do: :after_contract

    @impl true
    def call(pipeline) do
      put_in(pipeline.state.contract, %{pipeline.state.contract | tag: :tagged})
    end
  end

  defmodule FailingBeforeContract do
    use Middleware

    @impl true
    def call(pipeline) do
      Dobro.Pipeline.add_error(pipeline, Error.new(:middleware_failed))
    end
  end

  defp ctx do
    %ExecutionContext{
      tenant: TenantContext.new(%{id: 1, identifier: "acme"}),
      auth_context: %{actor: %{id: 9, type: "user"}}
    }
  end

  defp command do
    %Command{
      payload: %Payload{name: "Ada"},
      identity: nil,
      scope: {:tenant, :context}
    }
  end

  test "before_contract middleware enriches contract_attrs for Module.new/1" do
    pipeline =
      Pipeline.pipeline(command(), ctx(),
        contract: CreateContract,
        middleware: [InjectAuthorId]
      )

    assert %CreateContract{name: "Ada", author_id: 99} = pipeline.state.contract
    assert pipeline.state.contract_attrs.author_id == 99
  end

  test "before_contract middleware enriches contract_attrs for arity-2 contract fn" do
    contract_fn = fn attrs, _ctx ->
      CreateContract.new(attrs)
    end

    pipeline =
      Pipeline.pipeline(command(), ctx(),
        contract: contract_fn,
        middleware: [InjectAuthorId]
      )

    assert %CreateContract{name: "Ada", author_id: 99} = pipeline.state.contract
  end

  test "after_contract middleware runs after the contract is built" do
    pipeline =
      Pipeline.pipeline(command(), ctx(),
        contract: CreateContract,
        middleware: [TagAfterContract]
      )

    assert %CreateContract{tag: :tagged} = pipeline.state.contract
  end

  test "phase override via entry opts" do
    pipeline =
      Pipeline.pipeline(command(), ctx(),
        contract: CreateContract,
        middleware: [{InjectAuthorId, phase: :after_contract}]
      )

    # InjectAuthorId mutates contract_attrs, but after_contract runs too late for Module.new
    assert %CreateContract{author_id: nil} = pipeline.state.contract
    assert pipeline.state.contract_attrs.author_id == 99
  end

  test "middleware errors short-circuit before build_contract" do
    pipeline =
      Pipeline.pipeline(command(), ctx(),
        contract: CreateContract,
        middleware: [FailingBeforeContract, InjectAuthorId]
      )

    assert [%Error{reason: :middleware_failed}] = pipeline.errors
    assert pipeline.state.contract == %{}
    refute Map.has_key?(pipeline.state.contract_attrs, :author_id)
  end
end
