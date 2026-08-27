defmodule Dobro.Infra.Data.ReadRepo.SoftDeleteFilter do
  @moduledoc """
  Excludes soft-deleted rows from read-repo queries.
  """

  import Ecto.Query

  alias Dobro.Infra.Data.WriteRepo.DeleteStrategy

  @doc """
  Applies the configured soft-delete filter to a queryable.

  ## Examples

      SoftDeleteFilter.exclude_deleted(TemplateSchema, field: :deleted_at)
      SoftDeleteFilter.exclude_deleted(TemplateSchema, {SoftDelete.Boolean, field: :deleted})
  """
  @spec exclude_deleted(term(), term()) :: Ecto.Query.t()
  def exclude_deleted(queryable, {strategy_module, opts}) do
    exclude_deleted(queryable, strategy_filter(strategy_module, opts))
  end

  def exclude_deleted(queryable, field: field) when is_atom(field) do
    from(q in queryable, where: is_nil(field(q, ^field)))
  end

  def exclude_deleted(queryable, boolean_field: field, value: value) do
    from(q in queryable, where: field(q, ^field) != ^value)
  end

  def exclude_deleted(queryable, status_field: field, value: value) do
    from(q in queryable, where: field(q, ^field) != ^value)
  end

  defp strategy_filter(DeleteStrategy.SoftDelete.DateTime, opts),
    do: [field: Keyword.fetch!(opts, :field)]

  defp strategy_filter(DeleteStrategy.SoftDelete.Boolean, opts) do
    [boolean_field: Keyword.fetch!(opts, :field), value: Keyword.get(opts, :value, true)]
  end

  defp strategy_filter(DeleteStrategy.SoftDelete.Status, opts) do
    [status_field: Keyword.fetch!(opts, :field), value: Keyword.fetch!(opts, :value)]
  end
end
