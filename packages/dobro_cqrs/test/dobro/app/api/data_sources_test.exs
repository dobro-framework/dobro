defmodule Dobro.App.Api.DataSourcesTest do
  use ExUnit.Case, async: true

  alias Dobro.App.Api.DataSources
  alias Dobro.App.Auth.{AuthContext, SystemActor, TenantContext}
  alias Dobro.App.ExecutionContext
  alias Dobro.Error

  defmodule StubApi do
    def get_widget(%{id: id}, _ctx) do
      {:ok, %{id: id, status: "open", nested: %{email: "a@b.com"}}}
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
      "widgets.get_widget" => {StubApi, :get_widget},
      "widgets.boom" => {StubApi, :boom}
    }
  end

  test "resolve binds subject args and memos the result" do
    sources = %{
      "widget" => %{route: "widgets.get_widget", args: %{id: "$subject.id"}}
    }

    bindings = %{"subject" => %{"id" => 42, "type" => "widget"}, "tenant" => %{"id" => 9}}

    assert {:ok, %{"widget" => result}, memo} =
             DataSources.resolve(sources, bindings, ctx(), %{}, registry())

    assert result["id"] == 42
    assert result["status"] == "open"
    assert result["nested"]["email"] == "a@b.com"
    assert map_size(memo) == 1

    assert {:ok, %{"widget" => ^result}, ^memo} =
             DataSources.resolve(sources, bindings, ctx(), memo, registry())
  end

  test "resolve binds event paths and tenant id" do
    sources = %{
      "widget" => %{
        route: "widgets.get_widget",
        args: %{id: "$event.case_id"}
      }
    }

    bindings = %{
      "subject" => %{"id" => "ignored"},
      "tenant" => %{"id" => 9},
      "event" => %{"case_id" => 99, "lifecycle_status" => "active"}
    }

    assert {:ok, %{"widget" => %{"id" => 99}}, _} =
             DataSources.resolve(sources, bindings, ctx(), %{}, registry())
  end

  test "unknown and failing routes return errors" do
    bindings = %{"subject" => %{"id" => 1}, "tenant" => %{"id" => 9}}

    assert {:error, %Error{reason: :unknown_data_source}} =
             DataSources.resolve(
               %{"x" => %{route: "widgets.missing", args: %{}}},
               bindings,
               ctx(),
               %{},
               registry()
             )

    assert {:error, %Error{reason: :gone}} =
             DataSources.resolve(
               %{"x" => %{route: "widgets.boom", args: %{}}},
               bindings,
               ctx(),
               %{},
               registry()
             )
  end

  test "normalize_result stringifies keys and calendar types" do
    at = ~U[2026-01-02 03:04:05.000000Z]

    assert DataSources.normalize_result(%{id: 1, at: at, nested: %{ok: true}}) == %{
             "id" => 1,
             "at" => "2026-01-02T03:04:05.000000Z",
             "nested" => %{"ok" => true}
           }
  end
end
