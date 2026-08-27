defmodule Dobro.AI.ProviderContinuation do
  @moduledoc """
  Provider-agnostic handle for multi-turn LLM context held on the provider side.

  Stored in session metadata so adapters other than OpenAI can use their own
  `kind` values (e.g. Anthropic message thread ids).
  """

  @type t :: %{
          required(:provider) => String.t(),
          required(:kind) => String.t(),
          required(:id) => String.t()
        }

  @doc "Builds an OpenAI Responses API continuation from a response id."
  @spec openai_response(String.t()) :: t()
  def openai_response(id) when is_binary(id) do
    %{provider: "openai", kind: "previous_response_id", id: id}
  end

  @doc "Decodes continuation from session metadata."
  @spec from_map(map() | nil) :: t() | nil
  def from_map(%{"provider" => provider, "kind" => kind, "id" => id})
      when is_binary(provider) and is_binary(kind) and is_binary(id) do
    %{provider: provider, kind: kind, id: id}
  end

  def from_map(%{provider: provider, kind: kind, id: id})
      when is_binary(provider) and is_binary(kind) and is_binary(id) do
    %{provider: provider, kind: kind, id: id}
  end

  def from_map(_), do: nil

  @doc "Encodes continuation for session metadata."
  @spec to_map(t() | nil) :: map() | nil
  def to_map(%{provider: provider, kind: kind, id: id}) do
    %{"provider" => provider, "kind" => kind, "id" => id}
  end

  def to_map(_), do: nil

  @doc false
  @spec valid?(t() | nil) :: boolean()
  def valid?(%{id: id}) when is_binary(id) and id != "", do: true
  def valid?(_), do: false

  @doc false
  @spec continuation_invalid?(term()) :: boolean()
  def continuation_invalid?(%Dobro.Error{reason: :continuation_invalid}), do: true

  def continuation_invalid?(%Dobro.Error{description: description}) when is_binary(description) do
    down = String.downcase(description)

    Enum.any?([
      "previous_response_id",
      "response not found",
      "invalid response"
    ], &String.contains?(down, &1))
  end

  def continuation_invalid?(_), do: false
end
