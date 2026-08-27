defmodule Dobro.AI.Agent do
  @moduledoc """
  Tool-calling agent loop over Dobro API query routes.
  """

  alias Dobro.AI.{ApiCatalog, ApiToolExecutor, ProviderContinuation, ToolContract, ToolOutput}
  alias Dobro.AI.Ports.TextGeneration
  alias Dobro.App.ExecutionContext

  @default_max_steps 10

  @type progress_event ::
          {:thinking, non_neg_integer()}
          | {:tool_start, String.t(), map()}
          | {:tool_done, String.t(), map(), map()}

  @type on_progress :: (progress_event() -> any())

  @type complete_result :: %{
          required(:content) => String.t(),
          required(:messages) => [TextGeneration.message()],
          optional(:continuation) => ProviderContinuation.t() | nil
        }

  @type needs_input_result :: %{
          required(:question) => String.t(),
          required(:messages) => [TextGeneration.message()],
          optional(:continuation) => ProviderContinuation.t() | nil
        }

  @doc """
  Runs the agent loop until the model returns final content, asks for input, errors, or hits `max_steps`.

  Optional `on_progress` receives `{:thinking, step}`, `{:tool_start, name, args}`, and
  `{:tool_done, name, args, result}`. Tool args and results are JSON maps (possibly empty).

  Optional `allowlist` is a list of route atoms; when non-empty, only those routes
  are exposed as tools (after applying `:denylist` / `dynamic_denylist`).

  Optional `dynamic_denylist` is a `(messages) -> [route_atom]` callback merged with `:denylist`
  before each step so tools can be removed after data is already loaded in the turn.

  Optional `continuation` — provider continuation from a prior user turn (Responses API).

  Optional `fallback_messages` — full message history used when provider continuation is invalid.
  """
  @spec run([TextGeneration.message()], ExecutionContext.t(), keyword()) ::
          {:complete, complete_result()}
          | {:needs_input, needs_input_result()}
          | {:error, term()}
  def run(messages, execution_context, opts \\ []) when is_list(messages) do
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
    text_opts = Keyword.take(opts, [:model])
    needs_input? = Keyword.get(opts, :needs_input?, fn _ -> false end)
    parse_needs_input = Keyword.get(opts, :parse_needs_input, &Function.identity/1)
    on_progress = Keyword.get(opts, :on_progress, fn _ -> :ok end)
    continuation = Keyword.get(opts, :continuation)
    fallback_messages = Keyword.get(opts, :fallback_messages, messages)

    loop(
      messages,
      fallback_messages,
      execution_context,
      text_opts,
      max_steps,
      0,
      needs_input?,
      parse_needs_input,
      on_progress,
      opts,
      %{
        tool_cache: %{},
        continuation: continuation,
        continuation_retried: false,
        pending_tool_results: nil
      }
    )
  end

  defp loop(messages, _fallback, _ctx, _text_opts, max_steps, step, _needs_input?, _parse, _on_progress, _opts, _state)
       when step >= max_steps do
    {:error, {:max_steps_exceeded, messages}}
  end

  defp loop(
         messages,
         fallback_messages,
         ctx,
         text_opts,
         max_steps,
         step,
         needs_input?,
         parse_needs_input,
         on_progress,
         opts,
         state
       ) do
    notify(on_progress, {:thinking, step})
    {tools, routes} = tools_for_step(opts, messages)
    messages = compact_duplicate_tool_messages(messages, ctx)

    generate_opts =
      build_generate_opts(text_opts, tools, step, messages, state)

    case text_generation().generate(messages, generate_opts) do
      {:ok, %{content: content, tool_calls: nil} = result} when is_binary(content) and content != "" ->
        finish(content, messages, needs_input?, parse_needs_input, result[:continuation] || state.continuation)

      {:ok, %{tool_calls: tool_calls} = result} when is_list(tool_calls) and tool_calls != [] ->
        assistant = %{role: :assistant, content: nil, tool_calls: tool_calls}
        updated_messages = messages ++ [assistant]
        next_continuation = result[:continuation] || state.continuation

        case execute_tool_calls(tool_calls, routes, ctx, updated_messages, on_progress, state.tool_cache, opts) do
          {:ok, messages_with_tools, tool_cache, tool_results} ->
            case after_tools(opts, messages_with_tools) do
              :complete ->
                finish(
                  "",
                  messages_with_tools,
                  needs_input?,
                  parse_needs_input,
                  next_continuation
                )

              :continue ->
                loop(
                  messages_with_tools,
                  fallback_messages,
                  ctx,
                  text_opts,
                  max_steps,
                  step + 1,
                  needs_input?,
                  parse_needs_input,
                  on_progress,
                  opts,
                  %{
                    state
                    | tool_cache: tool_cache,
                      continuation: next_continuation,
                      pending_tool_results: tool_results
                  }
                )
            end

          {:halt, question, messages_with_tools, _tool_cache, _tool_results} ->
            finish_needs_input(question, messages_with_tools, next_continuation)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{content: content} = result} when is_binary(content) and content != "" ->
        finish(content, messages, needs_input?, parse_needs_input, result[:continuation] || state.continuation)

      {:ok, result} ->
        finish(Map.get(result, :content) || "", messages, needs_input?, parse_needs_input, result[:continuation] || state.continuation)

      {:error, %Dobro.Error{reason: :continuation_invalid}} ->
        retry_without_continuation(
          messages,
          fallback_messages,
          ctx,
          text_opts,
          max_steps,
          step,
          needs_input?,
          parse_needs_input,
          on_progress,
          opts,
          state
        )

      {:error, reason} ->
        {:error, {reason, messages}}
    end
  end

  defp retry_without_continuation(
         _messages,
         fallback_messages,
         ctx,
         text_opts,
         max_steps,
         step,
         needs_input?,
         parse_needs_input,
         on_progress,
         opts,
         %{continuation_retried: false} = state
       ) do
    loop(
      fallback_messages,
      fallback_messages,
      ctx,
      text_opts,
      max_steps,
      step,
      needs_input?,
      parse_needs_input,
      on_progress,
      opts,
      %{state | continuation: nil, continuation_retried: true, pending_tool_results: nil}
    )
  end

  defp retry_without_continuation(_messages, _fallback, _ctx, _text_opts, _max, _step, _needs_input?, _parse, _on_progress, _opts, _state) do
    {:error, %Dobro.Error{reason: :continuation_invalid, description: "Provider continuation expired"}}
  end

  defp build_generate_opts(text_opts, tools, step, messages, state) do
    base =
      text_opts
      |> Keyword.put(:tools, tools)
      |> maybe_put_continuation(state.continuation, step, messages, state.pending_tool_results)

    base
  end

  defp maybe_put_continuation(opts, nil, _step, _messages, _tool_results), do: Keyword.put(opts, :input_mode, :full)

  defp maybe_put_continuation(opts, continuation, _step, _messages, tool_results)
       when is_list(tool_results) and tool_results != [] do
    opts
    |> Keyword.put(:continuation, continuation)
    |> Keyword.put(:input_mode, :tool_results)
    |> Keyword.put(:tool_results, tool_results)
  end

  defp maybe_put_continuation(opts, continuation, 0, _messages, _tool_results) do
    opts
    |> Keyword.put(:continuation, continuation)
    |> Keyword.put(:input_mode, :user_turn)
  end

  defp maybe_put_continuation(opts, continuation, _step, messages, _tool_results) do
    tool_results = pending_tool_results_from_messages(messages)

    if tool_results != [] do
      opts
      |> Keyword.put(:continuation, continuation)
      |> Keyword.put(:input_mode, :tool_results)
      |> Keyword.put(:tool_results, tool_results)
    else
      Keyword.put(opts, :input_mode, :full)
    end
  end

  defp pending_tool_results_from_messages(messages) do
    messages
    |> Enum.flat_map(fn
      %{role: :tool, tool_call_id: call_id, content: output}
      when is_binary(call_id) and is_binary(output) ->
        [provider_tool_result(call_id, output)]

      _ ->
        []
    end)
    |> Enum.take(-10)
  end

  defp tools_for_step(opts, messages) do
    denylist = merged_denylist(opts, messages)
    allowlist = Keyword.get(opts, :allowlist)

    case {Keyword.get(opts, :tools), Keyword.get(opts, :routes)} do
      {tools, routes} when is_list(tools) and is_map(routes) ->
        filter_custom_tools(tools, routes, denylist, allowlist)

      _ ->
        ApiCatalog.build_tools(denylist: denylist, allowlist: allowlist)
    end
  end

  defp filter_custom_tools(tools, routes, denylist, allowlist) do
    denied = MapSet.new(denylist)
    allowed = allowlist_set(allowlist)

    routes =
      routes
      |> Enum.filter(fn {_name, {_mod, route}} ->
        not MapSet.member?(denied, route) and allowlisted?(allowed, route)
      end)
      |> Map.new()

    tools = Enum.filter(tools, fn tool -> Map.has_key?(routes, tool.function.name) end)
    {tools, routes}
  end

  defp allowlist_set(list) when is_list(list) and list != [], do: MapSet.new(list)
  defp allowlist_set(_), do: nil

  defp allowlisted?(nil, _route), do: true
  defp allowlisted?(%MapSet{} = allowlist, route), do: MapSet.member?(allowlist, route)

  defp merged_denylist(opts, messages) do
    static = Keyword.get(opts, :denylist, [])

    dynamic =
      case Keyword.get(opts, :dynamic_denylist) do
        fun when is_function(fun, 1) -> fun.(messages)
        _ -> []
      end

    Enum.uniq(static ++ dynamic)
  end

  defp after_tools(opts, messages) do
    case Keyword.get(opts, :after_tools) do
      fun when is_function(fun, 1) ->
        case fun.(messages) do
          :complete -> :complete
          _ -> :continue
        end

      _ ->
        :continue
    end
  end

  defp provider_tool_result(call_id, json) when is_binary(json) do
    %{call_id: call_id, output: ToolOutput.for_model(json)}
  end

  defp finish(content, messages, needs_input?, parse_needs_input, continuation) do
    assistant = %{role: :assistant, content: content}
    result_base = %{messages: messages ++ [assistant], continuation: continuation}

    if needs_input?.(content) do
      {:needs_input, Map.put(result_base, :question, parse_needs_input.(content))}
    else
      {:complete, Map.put(result_base, :content, content)}
    end
  end

  defp finish_needs_input(question, messages, continuation) do
    content = "NEEDS_INPUT: #{question}"
    assistant = %{role: :assistant, content: content}

    {:needs_input,
     %{
       question: question,
       messages: messages ++ [assistant],
       continuation: continuation
     }}
  end

  defp tool_cache_key(tool_call, ctx) do
    name = tool_name(tool_call)
    args = tool_call_args(tool_call, ctx)

    {name, ApiToolExecutor.cache_key_for_tool(name, args, ctx)}
  end

  defp execute_tool_calls(tool_calls, routes, ctx, messages, on_progress, tool_cache, opts) do
    executor_opts = Keyword.take(opts, [:contract_driven, :allowed_tenant_id])

    Enum.reduce(tool_calls, {:ok, messages, tool_cache, []}, fn
      tool_call, {:ok, acc, cache, tool_results} ->
        name = tool_name(tool_call)
        args = tool_args(tool_call)
        display_args = display_tool_args(name, args, routes, ctx, executor_opts)
        cache_key = tool_cache_key(tool_call, ctx)

        case Map.fetch(cache, cache_key) do
          {:ok, json} ->
            result = decode_tool_result(json)

            notify(on_progress, {:tool_start, name, display_args})
            notify(on_progress, {:tool_done, name, display_args, result})

            tool_message = %{
              role: :tool,
              tool_call_id: tool_call.id,
              content: json
            }

            messages_with_tool = acc ++ [tool_message]
            tool_results = tool_results ++ [provider_tool_result(tool_call.id, json)]

            case halt_from_tool_result?(result, name, args) do
              {:halt, question} ->
                {:halt, question, messages_with_tool, cache, tool_results}

              :ok ->
                {:ok, messages_with_tool, cache, tool_results}
            end

          :error ->
            notify(on_progress, {:tool_start, name, display_args})
            {:ok, json} = ApiToolExecutor.execute(tool_call, routes, ctx, executor_opts)
            result = decode_tool_result(json)
            notify(on_progress, {:tool_done, name, display_args, result})

            tool_message = %{
              role: :tool,
              tool_call_id: tool_call.id,
              content: json
            }

            messages_with_tool = acc ++ [tool_message]
            tool_results = tool_results ++ [provider_tool_result(tool_call.id, json)]
            cache = Map.put(cache, cache_key, json)

            case halt_from_tool_result?(result, name, args) do
              {:halt, question} ->
                {:halt, question, messages_with_tool, cache, tool_results}

              :ok ->
                {:ok, messages_with_tool, cache, tool_results}
            end
        end

      _tool_call, {:error, reason} ->
        {:error, reason}

      _tool_call, {:halt, _question, _messages, _cache, _tool_results} = halt ->
        halt
    end)
  end

  defp halt_from_tool_result?(result, name, args) when is_map(result) do
    if ToolContract.halt_result?(result) do
      {:halt, ToolContract.halt_message(result, name, args)}
    else
      :ok
    end
  end

  defp halt_from_tool_result?(_result, _name, _args), do: :ok

  defp compact_duplicate_tool_messages(messages, ctx) do
    call_keys = tool_call_keys(messages, ctx)

    last_indices =
      messages
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {message, index}, acc ->
        case duplicate_tool_key(message, call_keys) do
          nil -> acc
          key -> Map.put(acc, key, index)
        end
      end)

    messages
    |> Enum.with_index()
    |> Enum.reject(fn {message, index} ->
      case duplicate_tool_key(message, call_keys) do
        nil -> false
        key -> Map.get(last_indices, key) != index
      end
    end)
    |> Enum.map(&elem(&1, 0))
    |> drop_orphan_assistant_tool_calls()
  end

  defp tool_call_keys(messages, ctx) do
    messages
    |> Enum.flat_map(fn
      %{role: :assistant, tool_calls: calls} when is_list(calls) ->
        Enum.map(calls, fn call -> {call.id, duplicate_call_key(call, ctx)} end)

      _ ->
        []
    end)
    |> Map.new()
  end

  defp duplicate_call_key(call, ctx) do
    name = tool_name(call)
    args = tool_call_args(call, ctx)
    {:call, name, ApiToolExecutor.cache_key_for_tool(name, args, ctx)}
  end

  defp duplicate_tool_key(%{role: :tool, tool_call_id: id, content: content}, call_keys)
       when is_binary(id) do
    case Map.get(call_keys, id) do
      key when not is_nil(key) -> key
      _ -> duplicate_tool_key_from_content(content)
    end
  end

  defp duplicate_tool_key(%{role: :tool, content: content}, _call_keys) when is_binary(content) do
    duplicate_tool_key_from_content(content)
  end

  defp duplicate_tool_key(_message, _call_keys), do: nil

  defp duplicate_tool_key_from_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, payload} when is_map(payload) ->
        case tool_payload_key(payload) do
          nil -> nil
          key -> {:tool, key}
        end

      _ ->
        nil
    end
  end

  defp duplicate_tool_key_from_content(_), do: nil

  defp tool_payload_key(%{"id" => id, "values" => _}), do: {"tenant_management_archive_get_entry", id}
  defp tool_payload_key(%{id: id, values: _}), do: {"tenant_management_archive_get_entry", id}
  defp tool_payload_key(_), do: nil

  defp drop_orphan_assistant_tool_calls(messages) do
    tool_call_ids =
      messages
      |> Enum.filter(&match?(%{role: :tool}, &1))
      |> Enum.map(& &1.tool_call_id)
      |> MapSet.new()

    Enum.filter(messages, fn
      %{role: :assistant, tool_calls: tool_calls} when is_list(tool_calls) ->
        Enum.any?(tool_calls, fn call -> MapSet.member?(tool_call_ids, call.id) end)

      _ ->
        true
    end)
  end

  defp tool_name(%{function: %{name: name}}) when is_binary(name), do: name
  defp tool_name(%{"function" => %{"name" => name}}) when is_binary(name), do: name
  defp tool_name(_), do: "unknown"

  defp tool_args(%{function: %{arguments: arguments}}), do: decode_tool_args(arguments)
  defp tool_args(%{"function" => %{"arguments" => arguments}}), do: decode_tool_args(arguments)
  defp tool_args(_), do: %{}

  defp tool_call_args(%{function: %{arguments: arguments}}, ctx),
    do: ApiToolExecutor.normalize_tool_args(decode_tool_call_args(arguments), ctx)

  defp tool_call_args(%{"function" => %{"arguments" => arguments}}, ctx),
    do: ApiToolExecutor.normalize_tool_args(decode_tool_call_args(arguments), ctx)

  defp tool_call_args(_, _ctx), do: %{}

  defp decode_tool_call_args(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, map} when is_map(map) -> atomize_keys(map)
      _ -> %{}
    end
  end

  defp decode_tool_call_args(arguments) when is_map(arguments), do: atomize_keys(arguments)
  defp decode_tool_call_args(_), do: %{}

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {atomize_key(key), atomize_value(value)} end)
  end

  defp atomize_value(value) when is_map(value), do: atomize_keys(value)

  defp atomize_value(value) when is_list(value) do
    Enum.map(value, fn
      item when is_map(item) -> atomize_keys(item)
      item -> item
    end)
  end

  defp atomize_value(value), do: value

  defp atomize_key(key) when is_atom(key), do: key

  defp atomize_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> String.to_atom(key)
    end
  end

  defp decode_tool_args(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, map} when is_map(map) -> stringify_keys(map)
      _ -> %{}
    end
  end

  defp decode_tool_args(arguments) when is_map(arguments), do: stringify_keys(arguments)
  defp decode_tool_args(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_values(value)} end)
  end

  defp stringify_values(value) when is_map(value), do: stringify_keys(value)

  defp stringify_values(value) when is_list(value),
    do: Enum.map(value, &stringify_values/1)

  defp stringify_values(value), do: value

  defp decode_tool_result(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"raw" => String.slice(json, 0, 500)}
    end
  end

  defp display_tool_args(name, args, routes, ctx, executor_opts) do
    route_ref = Map.get(routes, name)
    ApiToolExecutor.display_args(args, route_ref, ctx, executor_opts)
  end

  defp notify(on_progress, event) when is_function(on_progress, 1) do
    on_progress.(event)
  rescue
    _ -> :ok
  end

  defp text_generation, do: TextGeneration.adapter()
end
