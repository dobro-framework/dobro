defmodule Dobro.App.CommandDefinition do
  @moduledoc """
  Command definition module
  """

  @doc """
  Macro for defining a command definition
  """
  defmacro __using__(_opts \\ []) do
    quote do
      import Dobro.App.CommandDefinition

      use Dobro.App.Definition
    end
  end

  defmacro description(text) when is_binary(text) do
    quote do
      Module.put_attribute(__MODULE__, :description, unquote(text))
    end
  end

  @doc """
  Macro for defining a command
  """
  defmacro command(module_name, do: block) do
    quote do
      defmodule unquote(module_name) do
        use Dobro.App.Definition
        use Dobro.App.Command
        import Dobro.App.CommandDefinition, only: [description: 1]

        unquote(block)

        @before_compile {Dobro.App.Definition, :__add_scope_fn__}
      end
    end
  end

  @doc """
  Macro for defining a command handler
  """
  defmacro command_handler(module_name, opts \\ [], do: block) do
    quote do
      defmodule unquote(module_name) do
        use Dobro.App.CommandHandler, unquote(opts)

        unquote(block)
      end
    end
  end
end
