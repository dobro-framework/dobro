defmodule Dobro.App.Api.CommandsTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Api.Commands
  alias Dobro.App.Auth.{AuthContext, SystemActor, TenantContext}
  alias Dobro.App.ExecutionContext
  alias Dobro.Error

  defmodule StubApi do
    def ensure_widget(%{identifier: id, subject_id: subject_id}, _ctx) do
      {:ok, %{id: 1, identifier: id, subject_id: subject_id}}
    end

    def boom(_args, _ctx), do: {:error, Error.new(:gone)}
  end

  defp ctx do
    ExecutionContext.new(
      auth_context: AuthContext.new(actor: SystemActor.new()),
      tenant: TenantContext.new(id: 9)
    )
  end

  defp registry do
    %{
      "widgets.ensure_widget" => {StubApi, :ensure_widget},
      "widgets.boom" => {StubApi, :boom}
    }
  end

  test "run binds subject templates and returns :ok" do
    args = %{identifier: "arrange", subject_id: "$subject.id"}
    bindings = %{"subject" => %{"id" => "77", "type" => "case"}, "tenant" => %{"id" => 9}}

    assert :ok =
             Commands.run("widgets.ensure_widget", args, bindings, ctx(), registry())
  end

  test "run returns unknown_command for missing keys" do
    assert {:error, %Error{reason: :unknown_command}} =
             Commands.run("widgets.missing", %{}, %{}, ctx(), registry())
  end

  test "run propagates route errors" do
    assert {:error, %Error{reason: :gone}} =
             Commands.run("widgets.boom", %{}, %{}, ctx(), registry())
  end
end
