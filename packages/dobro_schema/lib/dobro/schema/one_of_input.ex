defmodule Dobro.Schema.OneOfInput do
  @moduledoc """
  Exclusive keyed variant map: exactly one named variant must be set.

  Prefer `one_of/2` or `use Dobro.Schema.OneOf` on contracts. Transports such
  as GraphQL synthesize this keyed envelope for **input** one_ofs. This struct
  remains the internal representation of that envelope and for rare cases where
  keys are intentional at the schema layer.

  ## Example (prefer OneOf on the contract)

      field :params, ActionParams  # use Dobro.Schema.OneOf

  GraphQL will expose `@oneOf` fields derived from member modules.
  """

  defstruct [:variants]

  @type variant :: {atom(), term()}
  @type t :: %__MODULE__{variants: [variant()]}

  def new(variants) when is_list(variants) and variants != [] do
    unless Keyword.keyword?(variants) do
      raise ArgumentError, "one_of_input/1 expects a keyword list of name: type"
    end

    struct(__MODULE__, %{variants: variants})
  end

  @doc """
  Unwraps a one-of input map into `{:ok, {variant_name, value}}`.

  Accepts string or atom keys. Returns an error when zero or more than one
  variant is present, or when the key is not a registered variant.
  """
  def unwrap(%__MODULE__{variants: variants}, value) when is_map(value) do
    present =
      variants
      |> Enum.flat_map(fn {name, _type} ->
        cond do
          Map.has_key?(value, name) and not nil_value?(Map.get(value, name)) ->
            [{name, Map.get(value, name)}]

          Map.has_key?(value, Atom.to_string(name)) and
              not nil_value?(Map.get(value, Atom.to_string(name))) ->
            [{name, Map.get(value, Atom.to_string(name))}]

          true ->
            []
        end
      end)

    case present do
      [{name, variant_value}] ->
        {:ok, {name, variant_value}}

      [] ->
        {:error, :one_of_required}

      _multiple ->
        {:error, :one_of_exclusive}
    end
  end

  def unwrap(%__MODULE__{}, _), do: {:error, :one_of_required}

  @doc "Like `unwrap/2` but raises on error."
  def unwrap!(one_of_input, value) do
    case unwrap(one_of_input, value) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "invalid one_of input: #{inspect(reason)}"
    end
  end

  defp nil_value?(nil), do: true
  defp nil_value?(_), do: false
end
