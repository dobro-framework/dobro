defmodule Dobro.Query.WhereEqTest do
  use ExUnit.Case, async: true

  alias Dobro.Ecto.Test.Schemas.TemplateSchema
  alias Dobro.Query

  describe "where_eq/3" do
    test "builds an is_nil filter when value is nil" do
      query = TemplateSchema |> Query.where_eq(:tenant_id, nil)

      assert inspect(query) =~ "is_nil"
      refute inspect(query) =~ "== ^"
    end

    test "builds an equality filter when value is set" do
      query = TemplateSchema |> Query.where_eq(:tenant_id, 42)

      assert inspect(query) =~ "== ^42"
    end

    test "works for fields other than tenant_id" do
      query = TemplateSchema |> Query.where_eq(:category_id, nil)

      assert inspect(query) =~ "is_nil"
      assert inspect(query) =~ "category_id"
    end
  end
end
