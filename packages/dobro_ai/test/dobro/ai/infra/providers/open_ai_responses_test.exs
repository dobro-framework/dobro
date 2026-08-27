defmodule Dobro.AI.Infra.Providers.OpenAiResponsesTest do
  use ExUnit.Case, async: false

  alias Dobro.AI.Infra.Providers.OpenAi
  alias Dobro.AI.ProviderContinuation

  setup do
    Application.put_env(:dobro_ai, OpenAi, api_key: "test-key", api_mode: :responses)
    :ok
  end

  test "parses responses output with tool calls and continuation id" do
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.openai.com/v1/responses", body: body} ->
        decoded = if is_binary(body), do: Jason.decode!(body), else: body

        assert [%{"type" => "function", "name" => "demo_tool"}] = decoded["tools"]
        refute Map.has_key?(hd(decoded["tools"]), "function")

        %Tesla.Env{
          status: 200,
          body: %{
            "id" => "resp_test123",
            "output" => [
              %{
                "type" => "function_call",
                "call_id" => "call_99",
                "name" => "demo_tool",
                "arguments" => ~s({"x":1})
              }
            ],
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
          }
        }
    end)

    assert {:ok, result} =
             OpenAi.generate(
               [
                 %{role: :system, content: "system"},
                 %{role: :user, content: "hello"}
               ],
               input_mode: :full,
               tools: [
                 %{
                   type: "function",
                   function: %{
                     name: "demo_tool",
                     description: "demo",
                     parameters: %{"type" => "object"}
                   }
                 }
               ]
             )

    assert [%{id: "call_99", function: %{name: "demo_tool"}}] = result.tool_calls
    assert result.continuation == ProviderContinuation.openai_response("resp_test123")
  end

  test "chains tool results with previous_response_id" do
    Tesla.Mock.mock(fn
      %{method: :post, url: "https://api.openai.com/v1/responses", body: body} ->
        decoded = if is_binary(body), do: Jason.decode!(body), else: body

        assert decoded["previous_response_id"] == "resp_prev"
        assert [%{"type" => "function_call_output", "call_id" => "call_1"}] = decoded["input"]

        %Tesla.Env{
          status: 200,
          body: %{
            "id" => "resp_next",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "done"}]
              }
            ]
          }
        }
    end)

    continuation = ProviderContinuation.openai_response("resp_prev")

    assert {:ok, %{content: "done", continuation: %{id: "resp_next"}}} =
             OpenAi.generate(
               [],
               continuation: continuation,
               input_mode: :tool_results,
               tool_results: [%{call_id: "call_1", output: ~s({"ok":true})}]
             )
  end
end
