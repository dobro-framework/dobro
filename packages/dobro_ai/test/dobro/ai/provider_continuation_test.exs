defmodule Dobro.AI.ProviderContinuationTest do
  use ExUnit.Case, async: true

  alias Dobro.AI.ProviderContinuation

  test "round-trips through metadata map" do
    cont = ProviderContinuation.openai_response("resp_abc123")

    assert ProviderContinuation.from_map(ProviderContinuation.to_map(cont)) == cont
    assert ProviderContinuation.valid?(cont)
  end

  test "detects invalid continuation errors" do
    assert ProviderContinuation.continuation_invalid?(%Dobro.Error{
             description: "OpenAI returned 400: Unknown previous_response_id"
           })
  end
end
