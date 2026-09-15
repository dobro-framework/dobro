defmodule Dobro.Infra.Repo do
  @moduledoc false

  @doc "Returns the configured Ecto repo module."
  @spec repo() :: module()
  def repo, do: Dobro.Config.repo!()

  def aggregate(queryable, aggregate, field \\ nil) do
    if field do
      apply(repo(), :aggregate, [queryable, aggregate, field])
    else
      apply(repo(), :aggregate, [queryable, aggregate])
    end
  end
  def all(queryable, opts \\ []), do: apply(repo(), :all, [queryable, opts])
  def exists?(queryable, opts \\ []), do: apply(repo(), :exists?, [queryable, opts])
  def explain(operation, queryable, opts \\ []),
    do: apply(repo(), :explain, [operation, queryable, opts])
  def get(queryable, id, opts \\ []), do: apply(repo(), :get, [queryable, id, opts])
  def get!(queryable, id, opts \\ []), do: apply(repo(), :get!, [queryable, id, opts])
  def get_by(queryable, clauses, opts \\ []), do: apply(repo(), :get_by, [queryable, clauses, opts])
  def one(queryable, opts \\ []), do: apply(repo(), :one, [queryable, opts])
  def insert(struct, opts \\ []), do: apply(repo(), :insert, [struct, opts])
  def insert_all(schema, entries, opts \\ []), do: apply(repo(), :insert_all, [schema, entries, opts])
  def update(struct, opts \\ []), do: apply(repo(), :update, [struct, opts])
  def update_all(queryable, updates, opts \\ []),
    do: apply(repo(), :update_all, [queryable, updates, opts])
  def delete_all(queryable, opts \\ []), do: apply(repo(), :delete_all, [queryable, opts])
  def delete(struct, opts \\ []), do: apply(repo(), :delete, [struct, opts])
  def preload(struct_or_structs, preloads, opts \\ []),
    do: apply(repo(), :preload, [struct_or_structs, preloads, opts])
  def transaction(fun, opts \\ []), do: apply(repo(), :transaction, [fun, opts])
end
