defmodule Dobro.Domain.Specification do
  @moduledoc """
  Behaviour for domain specifications.

  Specifications validate a domain operation before it is applied to an aggregate.
  They receive a `Dobro.Domain.SpecificationContext` containing the domain contract
  and optional aggregate identity.

  They are useful when an invariant requires access to information outside the scope
  of a single aggregate. Ports can be provided to read cross-aggregate state.

  `path:` names the input field a failure applies to. The command pipeline copies
  it onto the error so the API can return it on that field. Omit it for a
  form-level error.
  """
  @callback satisfied_by?(Dobro.Domain.SpecificationContext.t()) :: boolean()

  defmacro __using__(opts) do
    ports = Keyword.get(opts, :ports, [])
    description = Keyword.get(opts, :description, nil)
    reason = Keyword.get(opts, :reason, :specification_failed)
    path = Keyword.get(opts, :path)

    quote location: :keep do
      @behaviour Dobro.Domain.Specification

      use Dobro.Spec.Consumer, ports: unquote(ports)

      def satisfied_by?(input) do
        raise "Not implemented"
      end

      defoverridable satisfied_by?: 1

      def description, do: unquote(description)
      def reason, do: unquote(reason)

      @doc "Input field this failure applies to, or nil for a form-level error."
      def path, do: unquote(path)
    end
  end
end
