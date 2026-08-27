defmodule Dobro.Domain.EventDefinition do
  @moduledoc """
  Macros for defining versioned domain events.

  ## Example

      defmodule MyApp.OrderEvents do
        use Dobro.Domain.EventDefinition

        defevent OrderPlaced do
          payload do
            field :order_id, :id
            field :total, :float
          end
        end
      end

  Events include `:payload`, `:message_identity`, and `:version` fields.
  See the [package README](readme.html) for the full event lifecycle.
  """

  alias Dobro.Domain.Messages.MessageIdentity

  @doc """
  Macro for defining an event definition
  """
  defmacro __using__(_opts \\ []) do
    quote do
      import Dobro.Domain.EventDefinition, only: [defevent: 2]
      use Dobro.Contract
    end
  end

  @doc """
  Macro for defining an event
  """
  defmacro defevent(module_name, do: block) do
    quote location: :keep do
      defmodule unquote(module_name) do
        use Dobro.Schema
        import Dobro.State
        alias Dobro.Pipeline
        import Dobro.Pipeline
        import Dobro.Domain.EventDefinition, only: [payload: 1]

        alias Dobro.Domain.Id
        alias Dobro.Domain.Messages.MessageIdentity

        schema do
          field :message_identity, MessageIdentity, required: true
          field :version, :integer, required: false
          unquote(block)
        end

        @doc """
        Creates a new event and autogenerates an identity unless one is provided
        """
        def new(%{payload: payload} = input) do
          input = maybe_generate_message_identity(%{payload: payload})

          Pipeline.new(
            state: %{value: Map.from_struct(%__MODULE__{})},
            input: input,
            config: %{schema_module: __MODULE__}
          )
          |> assign_all()
          |> cast()
        end

        # Generate ids if they are not provided
        defp maybe_generate_message_identity(%{} = input) do
          if is_nil(Map.get(input, :message_identity)) do
            id = Id.generate()

            message_identity =
              MessageIdentity.new!(%{id: id})

            Map.put(input, :message_identity, message_identity)
          else
            input
          end
        end

        @doc """
        Casts the event pipeline to an event struct
        """
        def cast(%Dobro.Pipeline{} = pipeline) do
          pipeline
          |> validate(__schema__())
          |> bind(fn pipeline ->
            put_in(pipeline.state, %{
              pipeline.state
              | value: struct(__MODULE__, pipeline.state.value)
            })
          end)
          |> finalize(:value)
        end
      end
    end
  end

  @doc """
  Macro for defining an event payload
  """
  defmacro payload(do: block) do
    quote do
      defcontract Payload do
        unquote(block)
      end

      field :payload, Payload, required: true
    end
  end
end
