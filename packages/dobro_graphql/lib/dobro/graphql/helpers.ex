defmodule Dobro.Graphql.Helpers do
  @moduledoc """
  Helper functions for GraphQL resolvers
   - Pagination formatting
   - Mutation payload formatting
   - Absinthe error formatting
  """

  defmodule Pagination do
    @moduledoc """
    Paginatio helpers for formatting paginated results in a consistent way
    """

    @doc """
    Formats a paginated result in the form of {items, meta} into a map with keys :items and :meta
    """
    def format({items, meta}) do
      %{items: items, meta: meta}
    end
  end

  defmodule Errors do
    @moduledoc """
    Formats `Dobro.Error` values into Absinthe-compatible query errors.
    """

    @doc """
    Formats resolver results so Absinthe can serialize query errors.

    Mutations should continue to use `Dobro.Graphql.Helpers.Mutation.payload/1`,
    which targets absinthe_error_payload validation messages.
    """
    def format({:ok, _} = result), do: result

    def format({:error, errors}) when is_list(errors) do
      {:error, Enum.map(errors, &format_query_error/1)}
    end

    def format({:error, %{errors: errors}}) when is_list(errors) do
      format({:error, errors})
    end

    def format({:error, %Dobro.Error{} = error}) do
      {:error, [format_query_error(error)]}
    end

    def format({:error, error}) when is_atom(error) do
      format({:error, Dobro.Error.new(error)})
    end

    def format(other), do: other

    @doc false
    def to_absinthe_error(%Dobro.Error{reason: reason, path: path, description: description}) do
      %{
        message: description,
        code: reason,
        field: path
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end

    def to_absinthe_error(error) when is_atom(error) do
      to_absinthe_error(Dobro.Error.new(error))
    end

    def to_absinthe_error(error) when is_binary(error), do: %{message: error}

    def to_absinthe_error(%{message: _} = error), do: error

    def to_absinthe_error(error), do: %{message: inspect(error)}

    defp format_query_error(error) do
      error
      |> to_absinthe_error()
      |> ensure_message()
    end

    defp ensure_message(%{message: message} = error) when is_binary(message), do: error

    defp ensure_message(%{code: code} = error) do
      Map.put(error, :message, humanize_reason(code))
    end

    defp ensure_message(error), do: Map.put(error, :message, "unknown error")

    defp humanize_reason(reason) when is_atom(reason) do
      reason
      |> Atom.to_string()
      |> String.replace("_", " ")
    end

    defp humanize_reason(reason), do: inspect(reason)
  end

  defmodule Mutation do
    @moduledoc """
    Helpers for formatting mutation results in a consistent way
    """

    require Logger

    @doc """
    Formats a mutation result in the form of {:ok, result} or {:error, error}
     - If the result is {:ok, result}, it will return the result
     - If the result is {:error, error}, it will return the list of errors formatted for Absinthe
    """
    def payload({:error, errors}) when is_list(errors) do
      {:error, Enum.map(errors, &to_validation_message/1)}
    end

    def payload({:error, %{errors: errors}}) when is_list(errors) do
      {:error, Enum.map(errors, &to_validation_message/1)}
    end

    def payload({:error, %Dobro.Error{} = error}) do
      {:error, [to_validation_message(error)]}
    end

    def payload({:error, error}) when is_atom(error) do
      {:error, [Dobro.Error.new(error) |> to_validation_message()]}
    end

    def payload({:ok, _} = result), do: result

    def payload(other) do
      Logger.error("Unexpected mutation resolver result: #{inspect(other, pretty: true, limit: 50)}")

      {:error,
       [
         to_validation_message(
           Dobro.Error.new(:internal_error, description: "internal server error")
         )
       ]}
    end

    defp to_validation_message(%Dobro.Error{reason: reason, path: path, description: description}) do
      %AbsintheErrorPayload.ValidationMessage{
        field: path,
        code: reason,
        message: human_description(description)
      }
    end

    defp to_validation_message(error) do
      formatted = Errors.to_absinthe_error(error)

      %AbsintheErrorPayload.ValidationMessage{
        field: Map.get(formatted, :field),
        code: Map.get(formatted, :code),
        message: human_description(Map.get(formatted, :message))
      }
    end

    # Only real copy becomes `message`. Reason atoms must not be echoed as
    # the user-facing message (clients translate via `code`).
    defp human_description(description) when is_binary(description), do: description
    defp human_description(_), do: nil
  end
end
