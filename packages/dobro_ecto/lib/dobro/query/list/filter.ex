defmodule Dobro.Query.List.Filter do
  @moduledoc """
  Flop-compatible filter operators for `Dobro.Query.List`.
  """

  import Ecto.Query

  alias Dobro.Infra.Data.Query.Spec

  @flop_ops [
    :==,
    :!=,
    :=~,
    :empty,
    :not_empty,
    :<=,
    :<,
    :>=,
    :>,
    :in,
    :not_in,
    :contains,
    :not_contains,
    :like,
    :not_like,
    :like_and,
    :like_or,
    :ilike,
    :not_ilike,
    :ilike_and,
    :ilike_or,
    :starts_with,
    :ends_with
  ]

  @pattern_ops [
    :like,
    :not_like,
    :like_and,
    :like_or,
    :ilike,
    :not_ilike,
    :ilike_and,
    :ilike_or,
    :=~,
    :starts_with,
    :ends_with
  ]

  @unmatchable :__dobro_unmatchable_filter__

  @doc "Returns true when `op` is a supported Flop operator."
  @spec valid_op?(term()) :: boolean()
  def valid_op?(op), do: match?({:ok, _}, parse_op(op))

  @doc "Parses a client filter operator into an internal Flop-compatible atom."
  @spec parse_op(term()) :: {:ok, atom()} | {:error, :invalid_op}
  def parse_op(op) when is_atom(op) do
    if op in @flop_ops, do: {:ok, op}, else: {:error, :invalid_op}
  end

  def parse_op(op) when is_binary(op) do
    op
    |> String.trim()
    |> String.downcase()
    |> parse_op_string()
  end

  def parse_op(_), do: {:error, :invalid_op}

  defp parse_op_string("=="), do: {:ok, :==}
  defp parse_op_string("="), do: {:ok, :==}
  defp parse_op_string("eq"), do: {:ok, :==}
  defp parse_op_string("!="), do: {:ok, :!=}
  defp parse_op_string("=~"), do: {:ok, :=~}
  defp parse_op_string("empty"), do: {:ok, :empty}
  defp parse_op_string("not_empty"), do: {:ok, :not_empty}
  defp parse_op_string("<="), do: {:ok, :<=}
  defp parse_op_string("<"), do: {:ok, :<}
  defp parse_op_string(">="), do: {:ok, :>=}
  defp parse_op_string(">"), do: {:ok, :>}
  defp parse_op_string("in"), do: {:ok, :in}
  defp parse_op_string("not_in"), do: {:ok, :not_in}
  defp parse_op_string("contains"), do: {:ok, :contains}
  defp parse_op_string("not_contains"), do: {:ok, :not_contains}
  defp parse_op_string("like"), do: {:ok, :like}
  defp parse_op_string("not_like"), do: {:ok, :not_like}
  defp parse_op_string("like_and"), do: {:ok, :like_and}
  defp parse_op_string("like_or"), do: {:ok, :like_or}
  defp parse_op_string("ilike"), do: {:ok, :ilike}
  defp parse_op_string("not_ilike"), do: {:ok, :not_ilike}
  defp parse_op_string("ilike_and"), do: {:ok, :ilike_and}
  defp parse_op_string("ilike_or"), do: {:ok, :ilike_or}
  defp parse_op_string("starts_with"), do: {:ok, :starts_with}
  defp parse_op_string("ends_with"), do: {:ok, :ends_with}
  defp parse_op_string(_), do: {:error, :invalid_op}

  @doc "Applies a filter to a queryable for the given field source."
  @spec apply(Ecto.Queryable.t(), term(), atom(), term()) :: Ecto.Queryable.t()
  def apply(queryable, source, op, value) do
    where(queryable, ^dynamic_condition(source, op, value))
  end

  @doc "Sentinel filter value that never matches a row."
  @spec unmatchable() :: atom()
  def unmatchable, do: @unmatchable

  @doc "Builds an Ecto dynamic for a field source + operator + value."
  @spec dynamic_condition(term(), atom(), term()) :: term()
  def dynamic_condition(_source, _op, @unmatchable), do: dynamic(false)

  def dynamic_condition({:column, binding, column}, op, value) do
    field = dynamic([{^binding, row}], field(row, ^column))
    condition(field, op, value)
  end

  def dynamic_condition({:join, join, column}, op, value) do
    field = dynamic([{^join, row}], field(row, ^column))
    condition(field, op, value)
  end

  def dynamic_condition({:expr, expr}, op, value) do
    condition(Spec.resolve_expr(expr), op, value)
  end

  @doc """
  Casts a filter value to the Ecto field type.

  GraphQL/API filter values arrive as strings (`Dobro.App.Types.Filter`), so
  integer/id/boolean/etc. columns need casting before the DB sees them.

  Pattern operators (`ilike`, `like`, …) keep the value as a string — they
  compare against the column cast to text, so Contains works on id columns.
  """
  @spec cast_value(Ecto.Type.t() | nil, atom(), term()) ::
          {:ok, term()} | {:error, :invalid_filter_value}
  def cast_value(_type, op, value) when op in [:empty, :not_empty], do: {:ok, value}

  def cast_value(_type, op, value) when op in @pattern_ops, do: {:ok, to_string_value(value)}

  def cast_value(nil, _op, value), do: {:ok, value}

  def cast_value(type, op, value) when op in [:in, :not_in] do
    value
    |> list_value()
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case cast_one(type, item) do
        {:ok, casted} -> {:cont, {:ok, [casted | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  def cast_value(type, _op, value), do: cast_one(type, value)

  defp cast_one(type, value) do
    case Ecto.Type.cast(type, value) do
      {:ok, casted} -> {:ok, casted}
      :error -> {:error, :invalid_filter_value}
    end
  end

  defp to_string_value(nil), do: ""
  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value), do: to_string(value)

  defp condition(field, :==, value), do: dynamic(^field == ^value)
  defp condition(field, :!=, value), do: dynamic(^field != ^value)
  defp condition(field, :<=, value), do: dynamic(^field <= ^value)
  defp condition(field, :<, value), do: dynamic(^field < ^value)
  defp condition(field, :>=, value), do: dynamic(^field >= ^value)
  defp condition(field, :>, value), do: dynamic(^field > ^value)

  defp condition(field, :in, value) do
    dynamic(^field in ^list_value(value))
  end

  defp condition(field, :not_in, value) do
    dynamic(^field not in ^list_value(value))
  end

  defp condition(field, :contains, value) do
    dynamic(fragment("? = ANY(?)", ^value, ^field))
  end

  defp condition(field, :not_contains, value) do
    dynamic(not fragment("? = ANY(?)", ^value, ^field))
  end

  defp condition(field, :empty, value) do
    if parse_boolean(value), do: dynamic(is_nil(^field)), else: dynamic(not is_nil(^field))
  end

  defp condition(field, :not_empty, value) do
    if parse_boolean(value), do: dynamic(not is_nil(^field)), else: dynamic(is_nil(^field))
  end

  defp condition(field, :like, value) do
    pattern = like_pattern(value, :contains)
    dynamic(like(fragment("(?)::text", ^field), ^pattern))
  end

  defp condition(field, :not_like, value) do
    pattern = like_pattern(value, :contains)
    dynamic(not like(fragment("(?)::text", ^field), ^pattern))
  end

  defp condition(field, :ilike, value) do
    pattern = like_pattern(value, :contains)
    dynamic(ilike(fragment("(?)::text", ^field), ^pattern))
  end

  defp condition(field, :not_ilike, value) do
    pattern = like_pattern(value, :contains)
    dynamic(not ilike(fragment("(?)::text", ^field), ^pattern))
  end

  defp condition(field, :=~, value) do
    pattern = like_pattern(value, :contains)
    dynamic(ilike(fragment("(?)::text", ^field), ^pattern))
  end

  defp condition(field, :starts_with, value) do
    pattern = like_pattern(value, :starts_with)
    dynamic(like(fragment("(?)::text", ^field), ^pattern))
  end

  defp condition(field, :ends_with, value) do
    pattern = like_pattern(value, :ends_with)
    dynamic(like(fragment("(?)::text", ^field), ^pattern))
  end

  defp condition(field, :like_and, value) do
    terms(value)
    |> Enum.reduce(dynamic(true), fn term, acc ->
      pattern = like_pattern(term, :contains)
      dynamic(^acc and like(fragment("(?)::text", ^field), ^pattern))
    end)
  end

  defp condition(field, :like_or, value) do
    terms(value)
    |> Enum.reduce(dynamic(false), fn term, acc ->
      pattern = like_pattern(term, :contains)
      dynamic(^acc or like(fragment("(?)::text", ^field), ^pattern))
    end)
  end

  defp condition(field, :ilike_and, value) do
    terms(value)
    |> Enum.reduce(dynamic(true), fn term, acc ->
      pattern = like_pattern(term, :contains)
      dynamic(^acc and ilike(fragment("(?)::text", ^field), ^pattern))
    end)
  end

  defp condition(field, :ilike_or, value) do
    terms(value)
    |> Enum.reduce(dynamic(false), fn term, acc ->
      pattern = like_pattern(term, :contains)
      dynamic(^acc or ilike(fragment("(?)::text", ^field), ^pattern))
    end)
  end

  defp list_value(value) when is_list(value), do: value

  defp list_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp list_value(value), do: List.wrap(value)

  defp terms(value) when is_list(value), do: value
  defp terms(value) when is_binary(value), do: String.split(value, ~r/\s+/, trim: true)
  defp terms(value), do: String.split(to_string_value(value), ~r/\s+/, trim: true)

  defp parse_boolean(value) when value in [true, "true", "1", 1], do: true
  defp parse_boolean(_), do: false

  defp like_pattern(value, kind), do: like_pattern_string(to_string_value(value), kind)

  defp like_pattern_string(value, :contains) do
    "%#{escape_like(value)}%"
  end

  defp like_pattern_string(value, :starts_with) do
    "#{escape_like(value)}%"
  end

  defp like_pattern_string(value, :ends_with) do
    "%#{escape_like(value)}"
  end

  defp escape_like(value) when is_binary(value) do
    String.replace(value, ["%", "_", "\\"], fn
      "\\" -> "\\\\"
      char -> "\\#{char}"
    end)
  end
end
