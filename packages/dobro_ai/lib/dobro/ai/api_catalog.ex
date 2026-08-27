defmodule Dobro.AI.ApiCatalog do
  @moduledoc """
  Builds OpenAI tool definitions from Dobro API query routes opted into the `:ai` surface.
  """

  alias Dobro.AI.JsonSchema
  alias Dobro.App.Api.Surface

  @type tool :: Dobro.AI.Ports.TextGeneration.tool()
  @type route_ref :: {module(), atom()}

  @doc """
  Returns OpenAI tool definitions and a lookup map from tool name to `{api_module, route}`.
  """
  @spec build_tools(keyword()) :: {[tool()], %{String.t() => route_ref()}}
  def build_tools(opts \\ []) do
    denylist = MapSet.new(Keyword.get(opts, :denylist, []))
    allowlist = allowlist_set(Keyword.get(opts, :allowlist))

    Surface.apis(:ai)
    |> Enum.flat_map(&tools_for_api/1)
    |> Enum.reject(fn {_tool_name, _tool, {_api, route_name}} ->
      MapSet.member?(denylist, route_name)
    end)
    |> Enum.filter(fn {_tool_name, _tool, {_api, route_name}} ->
      allowlisted?(allowlist, route_name)
    end)
    |> Enum.uniq_by(fn {tool_name, _tool, _route} -> tool_name end)
    # Stable order keeps OpenAI prompt-cache prefixes byte-identical across requests.
    |> Enum.sort_by(fn {tool_name, _tool, _route} -> tool_name end)
    |> then(fn entries ->
      tools = Enum.map(entries, fn {_name, tool, _route} -> tool end)

      routes =
        entries
        |> Map.new(fn {name, _tool, route_ref} -> {name, route_ref} end)

      {tools, routes}
    end)
  end

  defp allowlist_set(list) when is_list(list) and list != [], do: MapSet.new(list)
  defp allowlist_set(_), do: nil

  defp allowlisted?(nil, _route_name), do: true
  defp allowlisted?(%MapSet{} = allowlist, route_name), do: MapSet.member?(allowlist, route_name)

  defp tools_for_api(api_module) do
    Code.ensure_compiled!(api_module)

    api_module.__queries__()
    |> Enum.map(fn {route_name, {query_module, route_opts}} ->
      tool_name = tool_name(api_module, query_module)
      description = augment_query_description(query_module, effective_description(route_opts, query_module))

      parameters =
        query_module.__schema__()
        |> JsonSchema.from_schema()
        |> maybe_with_selection(query_module)

      tool = %{
        type: "function",
        function: %{
          name: tool_name,
          description: description || default_description(query_module, route_name),
          parameters: parameters
        }
      }

      {tool_name, tool, {api_module, route_name}}
    end)
  end

  defp effective_description(route_opts, query_module) do
    case Keyword.get(route_opts, :description) do
      description when is_binary(description) -> description
      _ -> query_module.__description__()
    end
  end

  defp default_description(query_module, route_name) do
    "Run #{inspect(query_module)} via API route #{inspect(route_name)}"
  end

  defp tool_name(api_module, query_module) do
    context = api_module.__context__()
    api_namespace = namespace_for_context(context)
    query_name = query_module |> Module.split() |> List.last() |> Macro.underscore()
    [api_namespace, query_name] |> Enum.reject(&is_nil/1) |> Enum.join("_")
  end

  defp namespace_for_context({_context, namespace}), do: namespace

  defp namespace_for_context(context) when is_atom(context) do
    context
    |> Module.split()
    |> Enum.slice(1..-1//1)
    |> Enum.map_join("_", &String.downcase/1)
  end

  defp maybe_with_selection(schema, query_module) do
    short_name = query_module |> Module.split() |> List.last()

    if String.starts_with?(short_name, "List") do
      JsonSchema.with_optional_selection(schema)
    else
      schema
    end
  end

  defp augment_query_description(query_module, description) when is_binary(description) do
    short_name = query_module |> Module.split() |> List.last()

    cond do
      String.starts_with?(short_name, "List") ->
        """
        #{description}

        **List tools return summary rows for discovery only** — use filters/query to find the record id, then call the matching get/detail tool for full field values. Never use list `items[]` as final ASSIGNS or markup data. Pass `selection: { fields: ["id"] }` (and `"name"` when needed) to avoid over-fetching. Use `page_size: 1` for the first/sample record. Never paginate (`page` is ignored — always the first page). A non-empty `items` array means records exist — use `items[0].id`.
        """
        |> String.trim()

      detail_query?(short_name) ->
        """
        #{description}

        **Use this get/detail tool (not list items) when resolving a single record's field values.** Do not pass `selection` — the full record is returned.
        """
        |> String.trim()

      true ->
        description
    end
  end

  defp detail_query?(short_name) when is_binary(short_name) do
    String.starts_with?(short_name, "Get") or String.contains?(short_name, "By")
  end
end
