defmodule Dobro.App.Projector do
  @moduledoc """
  Macro for defining a projection
  """
  defmacro __using__(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__) |> to_string()
    stream_name = Keyword.fetch!(opts, :stream_name)

    quote do
      use Dobro.App.EventHandler, stream_name: unquote(stream_name)
      import Dobro.App.Projector.ProjectionHelpers

      def handle(%{} = event) do
        # IO.inspect(event, label: "PROJECTING EVENT")
        update_projection(__MODULE__, event, unquote(name), unquote(stream_name))
      end

      def __ack_stream_name__ do
        "#{unquote(stream_name)}_ack"
      end

      def __name__ do
        unquote(name)
      end
    end
  end

  defmodule ProjectionVersion do
    @moduledoc """
    Projection version schema
    """
    use TypedEctoSchema

    @primary_key false

    typed_schema "projection_versions" do
      field :projection_name, :string, primary_key: true
      field :stream_name, :string, primary_key: true
      field :last_seen_event_number, :integer
      timestamps type: :naive_datetime_usec
    end
  end

  defmodule ProjectionHelpers do
    @moduledoc """
    Projection helpers
    """
    import Ecto.Query
    import Phoenix.PubSub

    alias Dobro.App.Projector.ProjectionTransaction

    # @todo: make this configurable
    @timeout 5000

    def notify_projection_updated(module, projection_name, event) do
      message =
        {:projection_updated, projection_name, event.message_identity.causation_id, event.version}

      # IO.inspect({module.__ack_stream_name__(), message}, label: "BROADCASTING TO ACK STREAM")

      broadcast(
        Dobro.Config.pubsub!(),
        module.__ack_stream_name__(),
        message
      )
    end

    def update_projection(module, event, projection_name, stream_name) do
      event_number = event.version
      projection_name = to_string(projection_name)
      stream_name = to_string(stream_name)

      projection_version = %ProjectionVersion{
        projection_name: projection_name,
        stream_name: stream_name,
        last_seen_event_number: event_number
      }

      # @todo: make this configurable
      prefix = "projections"

      update_projection_version =
        update_projection_version_query(
          projection_name,
          stream_name,
          event_number
        )

      case ProjectionTransaction.run(
             module,
             event,
             projection_version,
             update_projection_version,
             prefix,
             timeout: @timeout,
             pool_timeout: @timeout
           ) do
        {:ok, :ok} ->
          notify_and_ok(module, projection_name, event)

        {:ok, {:error, :already_seen_event}} ->
          notify_and_ok(module, projection_name, event)

        {:ok, {:error, error}} ->
          {:error, error}

        {:error, error} ->
          {:error, error}
      end
    end

    defp update_projection_version_query(projection_name, stream_name, event_number) do
      from(pv in ProjectionVersion,
        where:
          pv.projection_name == ^projection_name and pv.stream_name == ^stream_name and
            pv.last_seen_event_number < ^event_number,
        update: [set: [last_seen_event_number: ^event_number]]
      )
    end

    defp notify_and_ok(module, projection_name, event) do
      notify_projection_updated(module, projection_name, event)
      :ok
    end
  end
end
