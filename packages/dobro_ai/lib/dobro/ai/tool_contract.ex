defmodule Dobro.AI.ToolContract do
  @moduledoc """
  Contract-driven validation and result classification for AI tool calls.

  Uses Dobro query/command payload schemas (required fields from API contracts).
  """

  @halt_reasons ~w(missing_required not_found scope_error)

  @doc "Returns required payload field names as strings for a route."
  @spec required_fields({module(), atom()}) :: [String.t()]
  def required_fields({api_module, route_name}) do
    case route_schema_module(api_module, route_name) do
      mod when is_atom(mod) and mod != nil ->
        mod.__schema__()
        |> Enum.filter(fn {_name, {_type, opts}} -> Keyword.get(opts, :required, false) end)
        |> Enum.map(fn {name, _} -> Atom.to_string(name) end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  @doc """
  Validates that all contract-required fields are present with non-empty values.
  """
  @spec validate_required(map(), {module(), atom()}) :: :ok | {:error, [String.t()]}
  def validate_required(args, route_ref) when is_map(args) do
    missing =
      route_ref
      |> required_fields()
      |> Enum.reject(&present?(args, &1))

    if missing == [], do: :ok, else: {:error, missing}
  end

  @doc "True when the tool result should stop the turn and ask the user."
  @spec halt_result?(map()) :: boolean()
  def halt_result?(%{"ok" => false, "error" => %{"reason" => reason}}) when reason in @halt_reasons,
    do: true

  def halt_result?(%{"ok" => false, "reason" => reason}) when reason in @halt_reasons, do: true

  def halt_result?(_), do: false

  @doc "User-facing message for a halt tool result."
  @spec halt_message(map(), String.t(), map()) :: String.t()
  def halt_message(%{"message" => message}, _tool_name, _args) when is_binary(message) and message != "",
    do: message

  def halt_message(%{"ok" => false, "error" => %{"message" => message}}, _tool_name, _args)
      when is_binary(message) and message != "",
      do: message

  def halt_message(%{"ok" => false, "reason" => "missing_required", "fields" => fields}, tool_name, _args)
      when is_list(fields) do
    noun = if length(fields) == 1, do: "field", else: "fields"
    pronoun = if length(fields) == 1, do: "it", else: "them"

    "Missing required #{noun} for #{human_tool(tool_name)}: #{Enum.join(fields, ", ")}. Please provide #{pronoun} and try again."
  end

  def halt_message(%{"ok" => false, "reason" => "not_found"}, tool_name, args) do
    "No matching record found for #{human_tool(tool_name)}#{args_summary(args)}. Please check the name or id and try again, or tell me which record to use."
  end

  def halt_message(_result, tool_name, _args) do
    "Could not complete #{human_tool(tool_name)}. Please clarify what data to use and try again."
  end

  @doc "Builds a missing-required tool payload."
  @spec missing_required_payload([String.t()], String.t()) :: map()
  def missing_required_payload(fields, tool_name) when is_list(fields) do
    field_list = Enum.join(fields, ", ")
    noun = if length(fields) == 1, do: "field", else: "fields"
    pronoun = if length(fields) == 1, do: "this", else: "these"

    %{
      "ok" => false,
      "reason" => "missing_required",
      "fields" => fields,
      "message" =>
        "Missing required #{noun} for #{human_tool(tool_name)}: #{field_list}. Ask the user for #{pronoun} before calling the tool again."
    }
  end

  @doc "Builds a not-found tool payload from a successful but empty API result."
  @spec not_found_payload(String.t(), map()) :: map()
  def not_found_payload(tool_name, args) when is_binary(tool_name) and is_map(args) do
    %{
      "ok" => false,
      "reason" => "not_found",
      "message" =>
        "No matching record found for #{human_tool(tool_name)}#{args_summary(args)}. Stop and ask the user to confirm the correct name, id, or scope."
    }
  end

  @doc "Classifies a successful API result; returns `:not_found` when a lookup clearly matched nothing."
  @spec classify_success(term(), String.t()) :: :ok | :not_found
  def classify_success(%{items: items}, _tool_name) when is_list(items) and items == [], do: :not_found
  def classify_success(%{"items" => items}, _tool_name) when is_list(items) and items == [], do: :not_found
  def classify_success(nil, "tenant_management_archive_get_entry"), do: :not_found
  def classify_success(_result, _tool_name), do: :ok

  defp route_schema_module(api_module, route_name) do
    Code.ensure_loaded(api_module)

    cond do
      function_exported?(api_module, :__queries__, 1) ->
        case api_module.__queries__(route_name) do
          {mod, _} when is_atom(mod) ->
            Code.ensure_loaded(mod)
            mod

          _ ->
            nil
        end

      function_exported?(api_module, :__commands__, 1) ->
        case api_module.__commands__(route_name) do
          {mod, _} when is_atom(mod) ->
            Code.ensure_loaded(mod)
            mod

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp present?(args, field) do
    case field_value(args, field) do
      nil -> false
      "" -> false
      [] -> false
      %{} = map -> map_size(map) > 0
      _ -> true
    end
  end

  defp field_value(args, field) when is_binary(field) do
    Map.get(args, field) || Map.get(args, safe_existing_atom(field))
  end

  defp safe_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp human_tool(name) when is_binary(name) do
    name
    |> String.replace_prefix("tenant_management_", "")
    |> String.replace("_", " ")
  end

  defp args_summary(args) when map_size(args) == 0, do: ""

  defp args_summary(args) do
    parts =
      for key <- ["tenant_id", "import_id", "id", "identifier", "username", "name"],
          value = field_value(args, key),
          not is_nil(value) and value != "" do
        "#{key}=#{inspect(value)}"
      end

    if parts == [], do: "", else: " (#{Enum.join(parts, ", ")})"
  end
end
