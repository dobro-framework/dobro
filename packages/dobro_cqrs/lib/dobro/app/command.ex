defmodule Dobro.App.Command do
  @moduledoc """
  Command macro
  """

  alias Dobro.App.Command.Helpers

  defmacro __using__(_opts) do
    quote location: :keep do
      import Dobro.App.Command

      Module.register_attribute(__MODULE__, :payload_module, accumulate: false)
      Module.register_attribute(__MODULE__, :load_mode, accumulate: false)
      Module.put_attribute(__MODULE__, :load_mode, :required)

      defstruct payload: %{},
                identity: %{},
                scope: nil,
                message_identity: nil

      def new(%{} = args), do: Helpers.new(__MODULE__, args)

      @before_compile Dobro.App.Command
    end
  end

  defmacro __before_compile__(env) do
    load_mode = Module.get_attribute(env.module, :load_mode) || :required

    quote do
      def __load_mode__, do: unquote(load_mode)
    end
  end

  defmacro identity(do: block) do
    quote do
      defmodule Identity do
        @moduledoc "Identity fields used to locate the aggregate targeted by this command."
        use Dobro.App.Schema,
          defaults: [required: true]

        schema(do: unquote(block))
      end

      def __identity__, do: Identity
    end
  end

  @doc """
  Whether an identified load may miss (`:optional`) or must find the aggregate (`:required`).

  Default is `:required`. Use `load :optional` for create-or-update commands (e.g. Save).
  """
  defmacro load(mode) when mode in [:optional, :required] do
    quote do
      Module.put_attribute(__MODULE__, :load_mode, unquote(mode))
    end
  end

  defmacro payload(do: block) do
    quote do
      defmodule Payload do
        @moduledoc "Input fields accepted by this command."
        use Dobro.App.Schema

        schema(do: unquote(block))
      end

      @payload_module Payload
      def __payload__, do: Payload
    end
  end

  defmacro payload(contract) do
    quote do
      @payload_module unquote(contract)
      def __payload__, do: unquote(contract)
    end
  end
end
