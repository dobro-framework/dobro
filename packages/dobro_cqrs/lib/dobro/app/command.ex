defmodule Dobro.App.Command do
  @moduledoc """
  Command macro
  """

  alias Dobro.App.Command.Helpers

  defmacro __using__(_opts) do
    quote location: :keep do
      import Dobro.App.Command

      Module.register_attribute(__MODULE__, :payload_module, accumulate: false)

      defstruct payload: %{},
                identity: %{},
                scope: nil,
                message_identity: nil

      def new(%{} = args), do: Helpers.new(__MODULE__, args)
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
