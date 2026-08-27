defmodule Dobro.Schema.Validations do
  @moduledoc """
  Validation functions for primitives
  """
  alias Dobro.Error
  alias Dobro.Schema.Types

  def validate_attr(value, field, type, validators) do
    errors =
      Enum.reduce(validators, [], fn validator, acc ->
        case apply_validator(validator, field, value, type) do
          :ok ->
            acc

          {:error, error} ->
            [error | acc]
        end
      end)

    if Enum.empty?(errors) do
      :ok
    else
      {:error, errors}
    end
  end

  defp apply_validator(validator, field, value, type) do
    type_module = Types.type_module(type)

    case type_module.validate(value, validator) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(reason,
           path: field,
           description: "`#{field}` failed `#{validator_name(validator)}` validation"
         )}
    end
  end

  defp validator_name(validator) when is_atom(validator), do: to_string(validator)
  defp validator_name({name, _}), do: to_string(name)
end
