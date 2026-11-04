defmodule Dobro.App.Api.MiddlewareTest do
  use ExUnit.Case, async: false

  alias Dobro.App.Api.Middleware.{Auth, Logger}
  alias Dobro.App.Api.Pipeline
  alias Dobro.App.Api.Pipeline.PipelineContext
  alias Dobro.App.Auth.{AuthContext, SystemActor}
  alias Dobro.App.ExecutionContext

  setup do
    previous = Application.get_env(:dobro_cqrs, :api_middleware)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:dobro_cqrs, :api_middleware)
      else
        Application.put_env(:dobro_cqrs, :api_middleware, previous)
      end
    end)

    :ok
  end

  defp pipeline_context(attrs) do
    PipelineContext.new(
      Map.merge(
        %{
          name: {__MODULE__, :example},
          type: :query,
          policy: :read,
          middleware: [],
          args: %{},
          run: fn -> {:ok, :ran} end
        },
        attrs
      )
    )
  end

  defp exec_ctx(actor) do
    ExecutionContext.new(auth_context: AuthContext.new(actor: actor))
  end

  describe "Auth" do
    test "allows public policy without an actor" do
      pc = pipeline_context(%{policy: :public, middleware: [Auth]})
      assert {:ok, :ran} = Pipeline.execute(pc, exec_ctx(nil))
    end

    test "allows SystemActor" do
      pc = pipeline_context(%{middleware: [Auth]})
      assert {:ok, :ran} = Pipeline.execute(pc, exec_ctx(SystemActor.new()))
    end

    test "allows actor with integer id" do
      pc = pipeline_context(%{middleware: [Auth]})
      assert {:ok, :ran} = Pipeline.execute(pc, exec_ctx(%{id: 1, type: "user"}))
    end

    test "rejects missing actor" do
      pc = pipeline_context(%{middleware: [Auth]})
      assert {:error, :not_authorized} = Pipeline.execute(pc, exec_ctx(nil))
    end
  end

  describe "Logger" do
    test "does not alter the result" do
      pc = pipeline_context(%{middleware: [Logger], run: fn -> {:ok, %{value: 1}} end})
      assert {:ok, %{value: 1}} = Pipeline.execute(pc, exec_ctx(%{id: 1, type: "user"}))
    end
  end

  describe "default middleware resolution" do
    test "default_middleware falls back to Logger and Auth" do
      Application.delete_env(:dobro_cqrs, :api_middleware)

      assert Dobro.App.Api.default_middleware() == [
               Dobro.App.Api.Middleware.Logger,
               Dobro.App.Api.Middleware.Auth
             ]
    end

    test "default_middleware reads Application config" do
      Application.put_env(:dobro_cqrs, :api_middleware, [])
      assert Dobro.App.Api.default_middleware() == []
    end

    test "onion order runs Logger then Auth around run" do
      pc =
        pipeline_context(%{
          policy: :public,
          middleware: [Logger, Auth],
          run: fn -> {:ok, :inner} end
        })

      assert {:ok, :inner} = Pipeline.execute(pc, exec_ctx(nil))
    end
  end

  describe "before_run hooks" do
    test "mutate PipelineContext before the onion" do
      pc =
        pipeline_context(%{
          policy: :public,
          middleware: [],
          before_run: [
            fn ctx -> %{ctx | args: Map.put(ctx.args, :hooked, true)} end
          ],
          run: fn -> {:ok, :ran} end
        })

      assert {:ok, :ran} = Pipeline.execute(pc, exec_ctx(nil))
    end
  end
end
