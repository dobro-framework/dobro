defmodule Dobro.Graphql.Payload do
  @moduledoc """
  Mutation payload returned to GraphQL clients.

  `successful` says whether the command completed. `messages` lists failures.
  `result` is the object written on success.
  """

  use Absinthe.Schema.Notation

  @enforce_keys [:successful]
  defstruct successful: nil, messages: [], result: nil

  defmodule ValidationMessage do
    @moduledoc false

    @enforce_keys [:code]
    defstruct field: nil, code: nil, message: nil
  end

  @doc """
  Defines the payload object for one mutation result type.
  """
  defmacro payload_object(payload_name, result_object_name) do
    quote do
      object unquote(payload_name) do
        field :successful, non_null(:boolean),
          description: "Indicates if the mutation completed successfully or not."

        field :messages, list_of(:validation_message),
          description: "A list of failed validations. May be blank or null if mutation succeeded."

        field :result, unquote(result_object_name),
          description: "The object created/updated/deleted by the mutation. May be null if mutation failed."
      end
    end
  end

  object :validation_message do
    field :field, :string,
      description: "The input field the error applies to. Null when the error is not for one field."

    field :message, :string,
      description: "A message suitable for display. Match on code when the text is not stable."

    field :code, non_null(:string),
      description: "A stable code for the kind of validation that failed."
  end

  @doc """
  Wraps a resolved mutation value as a payload.

  Runs after the resolver. Success values become `%Payload{successful: true}`.
  Errors become `%Payload{successful: false}` and the resolution errors are cleared.
  """
  def build_payload(%{value: value, errors: []} = resolution, _config) do
    %{resolution | value: %__MODULE__{successful: true, result: value}}
  end

  def build_payload(%{errors: errors} = resolution, _config) do
    messages = Enum.map(errors, &prepare_message/1)

    %{resolution | value: %__MODULE__{successful: false, messages: messages}, errors: []}
  end

  defp prepare_message(%ValidationMessage{} = message) do
    %{message | field: camelize_field(message.field)}
  end

  defp prepare_message(message) when is_binary(message) do
    %ValidationMessage{code: :unknown, message: message}
  end

  defp prepare_message(message) when is_atom(message) do
    prepare_message(Atom.to_string(message))
  end

  defp prepare_message(message) do
    raise ArgumentError, "Unexpected validation message: #{inspect(message)}"
  end

  defp camelize_field(nil), do: nil

  defp camelize_field(field) do
    field
    |> to_string()
    |> Absinthe.Utils.camelize(lower: true)
  end
end
