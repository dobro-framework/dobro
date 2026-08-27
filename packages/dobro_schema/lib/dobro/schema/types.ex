defmodule Dobro.Schema.Types do
  @moduledoc """
  Primitive Schema types
  """

  alias Dobro.Schema.Types

  @types %{
    string: Types.String,
    integer: Types.Integer,
    float: Types.Float,
    datetime: Types.DateTime,
    map: Types.Map,
    id: Types.Integer,
    boolean: Types.Boolean,
    upload: Types.Upload
  }

  def types, do: Map.keys(@types)

  def type_exists?(type_atom) when is_atom(type_atom) do
    Map.has_key?(@types, type_atom)
  end

  def type_module(type_atom) when is_atom(type_atom) do
    Map.fetch!(@types, type_atom)
  end

  defmodule String do
    @moduledoc """
    String type
    """

    @compile {:no_warn_undefined, [ExPhoneNumber]}

    def new(value), do: to_string(value)

    def validate(value, :presence) when value == "",
      do: {:error, :required}

    def validate(_, :presence), do: :ok

    def validate(value, :phone_number) do
      if phone_number_validation_available?() do
        validate_phone_number(value)
      else
        :ok
      end
    end

    def validate(value, {:format, regex}) do
      regex = if is_binary(regex), do: Regex.compile!(regex), else: regex

      if is_binary(value) and Regex.match?(regex, value),
        do: :ok,
        else: {:error, :invalid_format}
    end

    def validate(value, {:min_length, min}) do
      if Elixir.String.length(value) >= min,
        do: :ok,
        else: {:error, :invalid_length}
    end

    defp validate_phone_number(value) do
      case ExPhoneNumber.parse(value, "") do
        {:ok, parsed} ->
          if ExPhoneNumber.is_valid_number?(parsed) do
            :ok
          else
            {:error, :invalid_format}
          end

        {:error, _} ->
          {:error, :invalid_format}
      end
    end

    defp phone_number_validation_available? do
      Code.ensure_loaded?(ExPhoneNumber) and function_exported?(ExPhoneNumber, :parse, 2)
    end
  end

  defmodule Integer do
    @moduledoc """
    Integer type
    """
    def new(value) when is_integer(value), do: value

    def new(value) do
      case Elixir.Integer.parse(value) do
        :error -> nil
        {value, _} -> value
      end
    end

    def validate(_value, _validator), do: :ok
  end

  defmodule Boolean do
    @moduledoc """
    Boolean type
    """
    def new(value) when is_boolean(value), do: value
    def new(_), do: nil

    def validate(_value, _validator), do: :ok
  end

  defmodule Float do
    @moduledoc """
    Float type
    """
    @spec new(binary()) :: nil | float()
    def new(value) do
      case Elixir.Float.parse(value) do
        :error -> nil
        {value, _} -> value
      end
    end

    def validate(_value, _validator), do: :ok
  end

  defmodule Map do
    @moduledoc """
    Map type
    """
    def new(value) when is_map(value), do: value
    def new(_), do: %{}

    def validate(value, :presence) when is_map(value) and map_size(value) > 0, do: :ok
    def validate(_, :presence), do: {:error, :required}
  end

  defmodule DateTime do
    @moduledoc """
    DateTime type
    """

    @compile {:no_warn_undefined, [Timex]}

    @date_time_formats [
      "{ISO:Extended}",
      "{YYYY}-{M}-{D} {h24}:{m}:{s}",
      "{D}/{M}/{YYYY} {h24}:{m}"
    ]

    def new(nil), do: nil

    def new(%Elixir.DateTime{} = value), do: value

    def new(%NaiveDateTime{} = value) do
      Elixir.DateTime.from_naive!(value, "Etc/UTC")
    end

    def new(value) when is_binary(value) do
      if timex_available?() do
        parse_with_timex(value)
      else
        parse_with_elixir(value)
      end
    end

    def new(_), do: nil

    def validate(_value, _validator), do: :ok

    defp parse_with_timex(value) do
      @date_time_formats
      |> Enum.find_value(fn fmt ->
        case Timex.parse(value, fmt) do
          {:ok, dt} -> normalize(dt)
          _ -> nil
        end
      end)
    end

    defp parse_with_elixir(value) do
      case Elixir.DateTime.from_iso8601(value) do
        {:ok, dt, _offset} ->
          dt

        _ ->
          case NaiveDateTime.from_iso8601(value) do
            {:ok, ndt} -> Elixir.DateTime.from_naive!(ndt, "Etc/UTC")
            _ -> nil
          end
      end
    end

    defp normalize(%Elixir.DateTime{} = dt), do: dt

    defp normalize(%NaiveDateTime{} = ndt) do
      Elixir.DateTime.from_naive!(ndt, "Etc/UTC")
    end

    defp normalize(_), do: nil

    defp timex_available? do
      Code.ensure_loaded?(Timex) and function_exported?(Timex, :parse, 2)
    end
  end

  defmodule Upload do
    @moduledoc """
    Upload type - maps from Plug.Upload
    """
    def new(%Plug.Upload{} = value), do: value
    def new(_), do: nil

    def validate(_value, _validator), do: :ok
  end
end
