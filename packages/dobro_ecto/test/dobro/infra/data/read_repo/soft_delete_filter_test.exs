defmodule Dobro.Infra.Data.ReadRepo.SoftDeleteFilterTest do
  use ExUnit.Case, async: true

  alias Dobro.Ecto.Test.Schemas.TemplateSchema
  alias Dobro.Infra.Data.ReadRepo.SoftDeleteFilter
  alias Dobro.Infra.Data.WriteRepo.DeleteStrategy.SoftDelete.{Boolean, DateTime, Status}

  test "excludes rows with a deleted_at timestamp" do
    query = SoftDeleteFilter.exclude_deleted(TemplateSchema, field: :deleted_at)

    assert %Ecto.Query{} = query
    assert String.contains?(inspect(query), "deleted_at")
  end

  test "excludes rows with a boolean deleted flag" do
    query =
      SoftDeleteFilter.exclude_deleted(TemplateSchema,
        boolean_field: :deleted,
        value: true
      )

    assert %Ecto.Query{} = query
    assert String.contains?(inspect(query), "deleted")
  end

  test "excludes rows with a deleted status" do
    query =
      SoftDeleteFilter.exclude_deleted(TemplateSchema,
        status_field: :status,
        value: "Deleted"
      )

    assert %Ecto.Query{} = query
    assert String.contains?(inspect(query), "status")
  end

  test "resolves strategy modules to filters" do
    datetime_query =
      SoftDeleteFilter.exclude_deleted(TemplateSchema, {DateTime, field: :deleted_at})

    boolean_query =
      SoftDeleteFilter.exclude_deleted(TemplateSchema, {Boolean, field: :deleted, value: true})

    status_query =
      SoftDeleteFilter.exclude_deleted(TemplateSchema,
        {Status, field: :status, value: "Deleted"}
      )

    assert %Ecto.Query{} = datetime_query
    assert %Ecto.Query{} = boolean_query
    assert %Ecto.Query{} = status_query
  end
end
