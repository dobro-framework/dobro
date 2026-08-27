defmodule Dobro.AI.JsonSchema do
  @moduledoc false

  alias Dobro.Schema.{ListOf, NonNull, OneOf}
  alias Dobro.Schema.Types

  @spec from_schema(keyword()) :: map()
  def from_schema(schema) when is_list(schema) do
    properties =
      schema
      |> Enum.map(fn {name, {type, opts}} ->
        {Atom.to_string(name), property_schema(type, opts)}
      end)
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Map.new()

    required =
      schema
      |> Enum.filter(fn {_name, {_type, opts}} -> Keyword.get(opts, :required, false) end)
      |> Enum.map(fn {name, _} -> Atom.to_string(name) end)
      |> Enum.sort()

    base = %{
      "type" => "object",
      "properties" => properties,
      "additionalProperties" => false
    }

    if required == [], do: base, else: Map.put(base, "required", required)
  end

  @selection_property %{
    "type" => "object",
    "description" =>
      "Optional field selection for list tools only. Prefer `[\"id\"]` (add `\"name\"` when disambiguating). Omit on get/detail tools — those always return the full record.",
    "properties" => %{
      "fields" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Scalar result fields to return."
      }
    },
    "additionalProperties" => false
  }

  @doc "Adds optional `selection` to every AI tool parameter schema."
  @spec with_optional_selection(map()) :: map()
  def with_optional_selection(%{"properties" => properties} = schema) do
    Map.put(schema, "properties", Map.put(properties, "selection", @selection_property))
  end

  def with_optional_selection(schema), do: schema

  defp property_schema(type, opts) do
    base = type_schema(type)

    case Keyword.get(opts, :description) do
      description when is_binary(description) -> Map.put(base, "description", description)
      _ -> base
    end
  end

  defp type_schema(%NonNull{of_type: of_type}), do: type_schema(of_type)

  defp type_schema(%ListOf{of_type: of_type}) do
    %{"type" => "array", "items" => type_schema(of_type)}
  end

  defp type_schema(%OneOf{of_types: types}) do
    %{"oneOf" => Enum.map(types, &type_schema/1)}
  end

  defp type_schema(type) when is_atom(type) do
    cond do
      Types.type_exists?(type) ->
        primitive_schema(type)

      Code.ensure_loaded?(type) and function_exported?(type, :__schema__, 0) ->
        from_schema(type.__schema__())

      true ->
        %{"type" => "string"}
    end
  end

  defp type_schema(type) when is_binary(type), do: %{"type" => "string"}

  defp type_schema(type) do
    case type do
      %{} = map -> map
      _ -> %{"type" => "string"}
    end
  end

  defp primitive_schema(:string), do: %{"type" => "string"}
  defp primitive_schema(:integer), do: %{"type" => "integer"}
  defp primitive_schema(:float), do: %{"type" => "number"}
  defp primitive_schema(:boolean), do: %{"type" => "boolean"}
  defp primitive_schema(:datetime), do: %{"type" => "string", "format" => "date-time"}
  defp primitive_schema(:map), do: %{"type" => "object"}
  defp primitive_schema(:id), do: %{"type" => "integer"}
  defp primitive_schema(:upload), do: %{"type" => "string"}
  defp primitive_schema(_), do: %{"type" => "string"}
end
