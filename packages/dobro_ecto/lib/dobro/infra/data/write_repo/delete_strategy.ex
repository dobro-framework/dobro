defmodule Dobro.Infra.Data.WriteRepo.DeleteStrategy do
  @moduledoc """
  Behaviour and resolution for write-repo delete strategies.

  Configured per repo via `on_delete:` when using `Dobro.Infra.Data.WriteRepo`.
  """

  alias Dobro.Infra.Data.WriteRepo.{Context, UnitOfWork}
  alias __MODULE__.HardDelete
  alias __MODULE__.EventOnly
  alias __MODULE__.SoftDelete

  @callback delete(UnitOfWork.t(), Context.t(), keyword()) ::
              {:ok, UnitOfWork.t()} | {:error, term()}

  @doc "Normalises `on_delete` configuration to `{module, opts}`."
  @spec resolve(term()) :: {module(), keyword()}
  def resolve(:hard_delete), do: {HardDelete, []}
  def resolve(:event_only), do: {EventOnly, []}
  def resolve({SoftDelete.DateTime, opts}), do: {SoftDelete.DateTime, opts}
  def resolve({SoftDelete.Boolean, opts}), do: {SoftDelete.Boolean, opts}
  def resolve({SoftDelete.Status, opts}), do: {SoftDelete.Status, opts}
  def resolve({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  def resolve(strategy) when is_atom(strategy), do: {strategy, []}

  def resolve(strategy),
    do: raise(ArgumentError, "invalid delete strategy: #{inspect(strategy)}")
end
