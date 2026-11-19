defmodule Dobro.App.Types do
  @moduledoc """
  Shared API types
  """
  use Dobro.App.Definition
  use Dobro.Enum

  defcontract Pagination do
    field :current_page, :integer, required: true
    field :page_size, :integer, required: true
    field :total_count, :integer, required: true
    field :total_pages, :integer, required: true
  end

  defcontract Identified do
    field :id, :id
  end

  defcontract Deleted do
    field :id, :id
  end

  defcontract Filter do
    field :field, :string, required: true
    field :op, :string, required: true
    field :value, :string, required: true
  end

  defenum SortDirection do
    description("Sort direction for list queries")

    value :asc, description: "Ascending"
    value :desc, description: "Descending"
  end

  defenum FilterLogic do
    description("How multiple filters are combined")

    value :and, description: "All filters must match"
    value :or, description: "Any filter may match"
  end

  defcontract Sort do
    field :field, :string, required: true
    field :direction, SortDirection, required: true
  end

  defenum Owner do
    description("Who owns a row, relative to the request")

    value :global, description: "Global rows, shared by every tenant"

    value :tenant,
      description: "Tenants' rows: the request tenant's, or every tenant's when working globally"
  end

  defcontract Query do
    field :owner, list_of(Owner),
      description:
        "Rows to list by owner. Default: the tenant's and global rows inside a tenant; global rows when working globally"

    field :order, list_of(Sort)
    field :limit, :integer
    field :page, :integer
    field :page_size, :integer
    field :filters, list_of(Filter), default: []
    field :filter_logic, FilterLogic, default: :and
  end
end
