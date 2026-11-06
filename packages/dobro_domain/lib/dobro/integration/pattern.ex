defmodule Dobro.Integration.Pattern do
  @moduledoc """
  Routing-key patterns for integration subscriptions.

  `*` matches one segment. `#` matches the rest of the key, including nothing.
  A pattern must start with a literal context prefix, so `#` alone is rejected.
  """

  @type segments :: [String.t()]

  @spec compile(String.t()) :: {:ok, segments()} | {:error, :bare_hash}
  def compile(pattern) when is_binary(pattern) do
    segments = String.split(pattern, ".", trim: false)

    cond do
      segments == [] or hd(segments) in ["#", "*"] ->
        {:error, :bare_hash}

      "#" in Enum.drop(segments, -1) ->
        {:error, :bare_hash}

      true ->
        {:ok, segments}
    end
  end

  @spec match?(String.t(), String.t()) :: boolean()
  def match?(pattern, routing_key) when is_binary(pattern) and is_binary(routing_key) do
    case compile(pattern) do
      {:ok, segments} -> match_segments(segments, String.split(routing_key, ".", trim: false))
      {:error, _} -> false
    end
  end

  @spec routing_key(String.t(), String.t()) :: String.t()
  def routing_key(topic, event_name) when is_binary(topic) and is_binary(event_name) do
    topic <> "." <> event_name
  end

  defp match_segments([], []), do: true
  defp match_segments(["#"], _), do: true
  defp match_segments(["*" | pattern], [_ | key]), do: match_segments(pattern, key)
  defp match_segments([same | pattern], [same | key]), do: match_segments(pattern, key)
  defp match_segments(_, _), do: false
end
