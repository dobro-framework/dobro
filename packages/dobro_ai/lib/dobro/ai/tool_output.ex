defmodule Dobro.AI.ToolOutput do
  @moduledoc """
  Compacts tool JSON before it is sent to the model.

  Full payloads stay on the agent message list for local use; the provider only
  needs a short confirmation that the call succeeded.
  """

  @max_bytes 4_096

  @doc "Returns `json` unchanged when small enough; otherwise a compact summary."
  @spec for_model(String.t()) :: String.t()
  def for_model(json) when is_binary(json) do
    if byte_size(json) <= @max_bytes do
      json
    else
      compact_json(json)
    end
  end

  def for_model(other), do: other

  defp compact_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} ->
        decoded
        |> compact_value()
        |> Jason.encode!()

      _ ->
        String.slice(json, 0, @max_bytes)
    end
  end

  defp compact_value(%{"ok" => false} = error), do: error

  defp compact_value(%{"items" => items} = map) when is_list(items) do
    %{
      "item_count" => length(items),
      "items" => Enum.map(Enum.take(items, 5), &compact_list_item/1),
      "truncated" => length(items) > 5
    }
    |> maybe_put(map, ["meta", "page", "page_size"])
  end

  defp compact_value(%{"values" => values} = map) when is_map(values) do
    %{
      "id" => Map.get(map, "id"),
      "name" => Map.get(values, "name") || Map.get(map, "name"),
      "field_count" => map_size(values),
      "record_loaded" => true
    }
    |> reject_nils()
  end

  defp compact_value(map) when is_map(map) do
    map
    |> Enum.take(20)
    |> Map.new()
    |> Map.put("truncated", true)
  end

  defp compact_value(other), do: other

  defp compact_list_item(item) when is_map(item) do
    item
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(["id", "name", "identifier", "status", "import_id", "reference"])
    |> reject_nils()
  end

  defp compact_list_item(item), do: item

  defp maybe_put(summary, map, keys) do
    Enum.reduce(keys, summary, fn key, acc ->
      case Map.get(map, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
