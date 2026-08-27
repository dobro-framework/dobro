defmodule Dobro.AI.SessionContext do
  @moduledoc """
  Behaviour for feature-specific AI session configuration.
  """

  alias Dobro.App.ExecutionContext

  @type snapshot :: map()

  @callback context_type() :: String.t()

  @callback policy() :: atom()

  @callback build_system_prompt() :: String.t()

  @callback build_turn_message(String.t(), snapshot(), ExecutionContext.t()) :: String.t()

  @callback agent_opts() :: keyword()

  @callback needs_input?(String.t()) :: boolean()

  @callback parse_needs_input(String.t()) :: String.t()

  @doc false
  def needs_input?(module, content) when is_binary(content) do
    module.needs_input?(content)
  end

  @doc false
  def parse_needs_input(module, content) when is_binary(content) do
    module.parse_needs_input(content)
  end
end
