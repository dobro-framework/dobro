defmodule Dobro.AI.Ports.TextGeneration do
  @moduledoc """
  Port for text generation via an external LLM provider.
  """

  use Dobro.Spec.Port

  @type role :: :system | :user | :assistant | :tool

  @type tool_call :: %{
          required(:id) => String.t(),
          required(:type) => String.t(),
          required(:function) => %{
            required(:name) => String.t(),
            required(:arguments) => String.t()
          }
        }

  @type message :: %{
          required(:role) => role(),
          optional(:content) => String.t() | nil,
          optional(:tool_calls) => [tool_call()],
          optional(:tool_call_id) => String.t()
        }

  @type tool :: %{
          required(:type) => String.t(),
          required(:function) => %{
            required(:name) => String.t(),
            required(:description) => String.t(),
            required(:parameters) => map()
          }
        }

  @type result :: %{
          required(:content) => String.t() | nil,
          optional(:tool_calls) => [tool_call()] | nil,
          optional(:continuation) => map() | nil
        }

  @doc """
  Generates model output.

  Options:
    * `:tools` — function tools (chat completions / responses)
    * `:model` — model override
    * `:continuation` — `%Dobro.AI.ProviderContinuation{}` from a prior turn/step
    * `:input_mode` — `:full` (default), `:user_turn`, or `:tool_results` (responses API)
    * `:tool_results` — list of `%{call_id, output}` for `:tool_results` mode
  """
  @callback generate(messages :: [message()], opts :: keyword()) ::
              {:ok, result()} | {:error, term()}
end
