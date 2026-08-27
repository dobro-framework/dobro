defmodule Dobro.AI.Infra.Providers.OpenAi do
  @moduledoc """
  OpenAI adapter for `Dobro.AI.Ports.TextGeneration`.

  Supports `:chat_completions` (default in test) and `:responses` (default in
  dev/prod) for provider-side conversation continuity via `previous_response_id`.

  Prompt caching is automatic for `gpt-4o-mini` and newer when the request
  prefix is ≥ 1024 tokens and byte-identical across calls.
  """

  use Dobro.Spec.Adapter, port: Dobro.AI.Ports.TextGeneration

  require Logger

  alias Dobro.AI.ProviderContinuation
  alias Dobro.AI.ToolOutput
  alias Dobro.Error

  @default_model "gpt-4o-mini"
  @http_timeout_ms 120_000
  @max_rate_limit_retries 3

  @impl true
  def generate(messages, opts \\ []) when is_list(messages) do
    api_key = config(:api_key)

    if is_binary(api_key) and api_key != "" do
      case api_mode() do
        :responses -> do_responses_generate(messages, opts)
        _ -> do_chat_generate(messages, opts)
      end
    else
      {:error,
       Error.new(:openai_not_configured,
         description: "OPENAI_API_KEY is not configured"
       )}
    end
  end

  defp api_mode do
    config(:api_mode, :responses)
  end

  # --- Responses API -----------------------------------------------------------------

  defp do_responses_generate(messages, opts, attempt \\ 0) do
    model = Keyword.get(opts, :model, config(:model, @default_model))
    tools = Keyword.get(opts, :tools, [])
    input_mode = Keyword.get(opts, :input_mode, :full)
    continuation = Keyword.get(opts, :continuation)

    body =
      %{model: model, store: true}
      |> maybe_put_instructions(messages, input_mode)
      |> maybe_put_responses_input(messages, opts)
      |> maybe_put_previous_response(continuation, input_mode)
      |> maybe_put_responses_tools(tools)

    case client() |> Tesla.post("/v1/responses", body) do
      {:ok, %Tesla.Env{status: status, body: body}} when status in 200..299 ->
        log_responses_usage(model, body)
        parse_responses_body(body)

      {:ok, %Tesla.Env{status: 429, body: body}} when attempt < @max_rate_limit_retries ->
        sleep_ms = rate_limit_backoff_ms(body, attempt)
        Logger.warning("openai.responses rate_limited retry=#{attempt + 1} sleep_ms=#{sleep_ms}")
        Process.sleep(sleep_ms)
        do_responses_generate(messages, opts, attempt + 1)

      {:ok, %Tesla.Env{status: status, body: body}} when status in 400..499 ->
        Logger.warning("openai.responses failed status=#{status} #{openai_error_description(status, body)}")

        if continuation_invalid?(status, body) and ProviderContinuation.valid?(continuation) do
          {:error,
           Error.new(:continuation_invalid,
             description: openai_error_description(status, body)
           )}
        else
          {:error,
           Error.new(:openai_request_failed,
             description: openai_error_description(status, body)
           )}
        end

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error,
         Error.new(:openai_request_failed,
           description: openai_error_description(status, body)
         )}

      {:error, reason} ->
        {:error,
         Error.new(:openai_unreachable,
           description: "OpenAI request failed: #{inspect(reason)}"
         )}
    end
  end

  defp maybe_put_instructions(body, messages, :full) do
    case system_instructions(messages) do
      nil -> body
      instructions -> Map.put(body, :instructions, instructions)
    end
  end

  defp maybe_put_instructions(body, _messages, _mode), do: body

  defp maybe_put_previous_response(body, continuation, mode)
       when mode in [:user_turn, :tool_results] do
    if ProviderContinuation.valid?(continuation) do
      Map.put(body, :previous_response_id, continuation.id)
    else
      body
    end
  end

  defp maybe_put_previous_response(body, _continuation, _mode), do: body

  defp maybe_put_responses_input(body, messages, opts) do
    case Keyword.get(opts, :input_mode, :full) do
      :tool_results ->
        tool_results = Keyword.get(opts, :tool_results, [])

        Map.put(
          body,
          :input,
          Enum.map(tool_results, fn %{call_id: call_id, output: output} ->
            %{type: "function_call_output", call_id: call_id, output: ToolOutput.for_model(output)}
          end)
        )

      :user_turn ->
        Map.put(body, :input, responses_user_input(latest_user_message(messages)))

      :full ->
        Map.put(body, :input, responses_full_input(messages))
    end
  end

  defp responses_full_input(messages) do
    messages
    |> Enum.reject(&match?(%{role: :system}, &1))
    |> Enum.map(&format_responses_input_item/1)
  end

  defp responses_user_input(content) when is_binary(content) do
    [%{role: "user", content: content}]
  end

  defp responses_user_input(_), do: []

  defp format_responses_input_item(%{role: :user, content: content}) do
    %{role: "user", content: content}
  end

  defp format_responses_input_item(%{role: :assistant, content: content, tool_calls: tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    %{role: "assistant", content: blank_to_nil(content), tool_calls: Enum.map(tool_calls, &format_tool_call/1)}
  end

  defp format_responses_input_item(%{role: :assistant, content: content}) do
    %{role: "assistant", content: content}
  end

  defp format_responses_input_item(%{role: :tool, tool_call_id: tool_call_id, content: content}) do
    %{type: "function_call_output", call_id: tool_call_id, output: ToolOutput.for_model(content)}
  end

  defp system_instructions(messages) do
    messages
    |> Enum.find_value(fn
      %{role: :system, content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp latest_user_message(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :user, content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp parse_responses_body(%{"id" => id} = body) do
    output = Map.get(body, "output", [])

    tool_calls =
      output
      |> Enum.flat_map(fn
        %{"type" => "function_call"} = item -> [parse_responses_function_call(item)]
        _ -> []
      end)

    content =
      output
      |> Enum.find_value(fn
        %{"type" => "message", "content" => parts} when is_list(parts) ->
          extract_output_text(parts)

        _ ->
          nil
      end)

    result = %{
      content: content && String.trim(content),
      tool_calls: if(tool_calls == [], do: nil, else: tool_calls),
      continuation: ProviderContinuation.openai_response(id)
    }

    cond do
      result.tool_calls != nil -> {:ok, Map.put(result, :content, blank_to_nil(result.content))}
      is_binary(result.content) and result.content != "" -> {:ok, Map.put(result, :tool_calls, nil)}
      true -> {:ok, %{content: nil, tool_calls: nil, continuation: ProviderContinuation.openai_response(id)}}
    end
  end

  defp parse_responses_body(body) do
    {:error,
     Error.new(:openai_request_failed,
       description: "OpenAI returned unexpected responses payload: #{inspect(body, limit: 400)}"
     )}
  end

  defp parse_responses_function_call(%{"call_id" => call_id, "name" => name} = item) do
    %{
      id: call_id,
      type: "function",
      function: %{
        name: name,
        arguments: Map.get(item, "arguments", "{}")
      }
    }
  end

  defp extract_output_text(parts) do
    parts
    |> Enum.flat_map(fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp continuation_invalid?(status, body) when status in 400..499 do
    description = openai_error_description(status, body)
    ProviderContinuation.continuation_invalid?(%Error{description: description})
  end

  defp continuation_invalid?(_, _), do: false

  defp log_responses_usage(model, %{"usage" => usage}) when is_map(usage) do
    summary = usage_summary(usage)

    Logger.info(
      "openai.responses model=#{model} " <>
        "input_tokens=#{inspect(summary.prompt_tokens)} " <>
        "cached_tokens=#{inspect(summary.cached_tokens)} " <>
        "output_tokens=#{inspect(summary.completion_tokens)}"
    )
  end

  defp log_responses_usage(model, _body) do
    Logger.info("openai.responses model=#{model} usage=unknown")
  end

  # --- Chat Completions API (test / fallback) --------------------------------------

  defp do_chat_generate(messages, opts, attempt \\ 0) do
    model = Keyword.get(opts, :model, config(:model, @default_model))
    tools = Keyword.get(opts, :tools, [])

    body =
      %{
        model: model,
        messages: Enum.map(messages, &format_message/1)
      }
      |> maybe_put_chat_tools(tools)

    case client() |> Tesla.post("/v1/chat/completions", body) do
      {:ok,
       %Tesla.Env{
         status: status,
         body: %{"choices" => [%{"message" => message} | _]} = response_body
       }}
      when status in 200..299 ->
        log_chat_usage(model, length(messages), length(tools), Map.get(response_body, "usage"))

        case parse_message(message) do
          parsed -> {:ok, Map.put(parsed, :continuation, nil)}
        end

      {:ok, %Tesla.Env{status: 429, body: body}} when attempt < @max_rate_limit_retries ->
        sleep_ms = rate_limit_backoff_ms(body, attempt)
        Logger.warning("openai.chat_completions rate_limited retry=#{attempt + 1} sleep_ms=#{sleep_ms}")
        Process.sleep(sleep_ms)
        do_chat_generate(messages, opts, attempt + 1)

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error,
         Error.new(:openai_request_failed,
           description: openai_error_description(status, body)
         )}

      {:error, reason} ->
        {:error,
         Error.new(:openai_unreachable,
           description: "OpenAI request failed: #{inspect(reason)}"
         )}
    end
  end

  defp rate_limit_backoff_ms(body, attempt) do
    base =
      case body do
        %{"error" => %{"message" => message}} when is_binary(message) ->
          case Regex.run(~r/try again in ([\d.]+)s/i, message) do
            [_, seconds] -> trunc(String.to_float(seconds) * 1000)
            _ -> 3000
          end

        _ ->
          3000
      end

    base + attempt * 500 + 200
  end

  defp maybe_put_chat_tools(body, []), do: body

  defp maybe_put_chat_tools(body, tools) do
    formatted =
      Enum.map(tools, fn
        %{type: "function", function: function} ->
          %{type: "function", function: function}

        %{function: function} ->
          %{type: "function", function: function}

        other ->
          other
      end)

    Map.put(body, :tools, formatted)
  end

  defp maybe_put_responses_tools(body, []), do: body

  defp maybe_put_responses_tools(body, tools) do
    Map.put(body, :tools, Enum.map(tools, &format_responses_tool/1))
  end

  defp format_responses_tool(tool) do
    function = Map.get(tool, :function) || Map.get(tool, "function") || tool

    %{
      type: "function",
      name: tool_field(function, :name),
      description: tool_field(function, :description) || "",
      parameters: tool_field(function, :parameters) || %{"type" => "object", "properties" => %{}}
    }
  end

  defp tool_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  @doc false
  @spec usage_summary(map() | nil) :: map()
  def usage_summary(nil), do: %{prompt_tokens: nil, cached_tokens: 0, completion_tokens: nil}

  def usage_summary(usage) when is_map(usage) do
    cached =
      get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        get_in(usage, [:prompt_tokens_details, :cached_tokens]) ||
        get_in(usage, ["input_tokens_details", "cached_tokens"]) ||
        get_in(usage, [:input_tokens_details, :cached_tokens]) ||
        0

    %{
      prompt_tokens:
        Map.get(usage, "prompt_tokens") || Map.get(usage, :prompt_tokens) ||
          Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens),
      cached_tokens: cached,
      completion_tokens:
        Map.get(usage, "completion_tokens") || Map.get(usage, :completion_tokens) ||
          Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens)
    }
  end

  defp log_chat_usage(model, message_count, tool_count, usage) do
    summary = usage_summary(usage)
    prompt = summary.prompt_tokens
    cached = summary.cached_tokens

    cache_hit_pct =
      cond do
        is_integer(prompt) and prompt > 0 and is_integer(cached) ->
          Float.round(cached / prompt * 100, 1)

        true ->
          0.0
      end

    Logger.info(
      "openai.chat_completions model=#{model} messages=#{message_count} tools=#{tool_count} " <>
        "prompt_tokens=#{inspect(prompt)} cached_tokens=#{inspect(cached)} " <>
        "cache_hit_pct=#{cache_hit_pct} completion_tokens=#{inspect(summary.completion_tokens)}"
    )
  end

  defp parse_message(%{"content" => content, "tool_calls" => tool_calls})
       when is_list(tool_calls) and tool_calls != [] do
    %{
      content: blank_to_nil(content),
      tool_calls: Enum.map(tool_calls, &parse_tool_call/1)
    }
  end

  defp parse_message(%{"content" => content}) when is_binary(content) do
    %{content: String.trim(content), tool_calls: nil}
  end

  defp parse_message(%{"tool_calls" => tool_calls}) when is_list(tool_calls) and tool_calls != [] do
    %{content: nil, tool_calls: Enum.map(tool_calls, &parse_tool_call/1)}
  end

  defp parse_message(_), do: %{content: nil, tool_calls: nil}

  defp parse_tool_call(%{"id" => id, "type" => type, "function" => function}) do
    %{
      id: id,
      type: type,
      function: %{
        name: Map.fetch!(function, "name"),
        arguments: Map.get(function, "arguments", "{}")
      }
    }
  end

  defp format_message(%{role: role} = message) when is_binary(role) do
    format_message(%{message | role: normalize_role(role)})
  end

  defp format_message(%{role: :tool, tool_call_id: tool_call_id, content: content}) do
    %{role: "tool", tool_call_id: tool_call_id, content: ToolOutput.for_model(content)}
  end

  defp format_message(%{role: role, content: content, tool_calls: tool_calls})
       when role in [:assistant] and is_list(tool_calls) do
    %{
      role: Atom.to_string(role),
      content: blank_to_nil(content),
      tool_calls: Enum.map(tool_calls, &format_tool_call/1)
    }
  end

  defp format_message(%{role: role, content: content}) when role in [:system, :user, :assistant] do
    %{role: Atom.to_string(role), content: content}
  end

  defp format_tool_call(%{
         id: id,
         type: type,
         function: %{name: name, arguments: arguments}
       }) do
    %{
      id: id,
      type: type,
      function: %{name: name, arguments: arguments}
    }
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(content), do: content

  defp normalize_role("system"), do: :system
  defp normalize_role("user"), do: :user
  defp normalize_role("assistant"), do: :assistant
  defp normalize_role("tool"), do: :tool

  defp client do
    middleware = [
      {Tesla.Middleware.BaseUrl, "https://api.openai.com"},
      {Tesla.Middleware.Headers,
       [
         {"authorization", "Bearer #{config(:api_key)}"},
         {"content-type", "application/json"}
       ]},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Timeout, timeout: @http_timeout_ms}
    ]

    Tesla.client(middleware)
  end

  defp config(key, default \\ nil) do
    Application.get_env(:dobro_ai, __MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp openai_error_description(status, %{"error" => %{"message" => message}})
       when is_binary(message) do
    "OpenAI returned #{status}: #{message}"
  end

  defp openai_error_description(status, body) do
    "OpenAI returned #{status}: #{inspect(body, limit: 500)}"
  end
end
