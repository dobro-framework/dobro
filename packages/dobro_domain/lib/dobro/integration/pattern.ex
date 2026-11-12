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

  @doc """
  Every pattern that matches `routing_key`, including the key itself.

  Callers use this to select stored events in one query. A stored value such as
  `my_bc.#` is included when it matches; a bare `#` is not.
  """
  @spec covering(String.t()) :: [String.t()]
  def covering(routing_key) when is_binary(routing_key) do
    segments = String.split(routing_key, ".", trim: false)

    segments
    |> pattern_lists()
    |> Enum.map(&Enum.join(&1, "."))
    |> Enum.uniq()
    |> Enum.filter(fn candidate -> __MODULE__.match?(candidate, routing_key) end)
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

  defp pattern_lists(segments) do
    hashed =
      1..length(segments)
      |> Enum.flat_map(fn prefix_length ->
        segments
        |> Enum.take(prefix_length)
        |> expand()
        |> Enum.map(&(&1 ++ ["#"]))
      end)

    expand(segments) ++ hashed
  end

  defp expand(segments) do
    Enum.reduce(segments, [[]], fn segment, acc ->
      Enum.flat_map(acc, fn prefix ->
        [prefix ++ [segment], prefix ++ ["*"]]
      end)
    end)
  end
end
