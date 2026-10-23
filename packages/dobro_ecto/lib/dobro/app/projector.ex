defmodule Dobro.App.Projector do
  @moduledoc """
  Macro for defining a projection.

  Idempotency is tracked per `(projection_name, stream_name, partition_key)` where
  `partition_key` defaults to the aggregate id from `event.payload.id` (falling
  back to the event message id). That allows many create-only aggregates that
  each emit version `1` on a shared module stream (e.g. notes) without skipping
  later creates, while still ordering versions within a single aggregate
  (e.g. category rename/move).
  """
  defmacro __using__(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__) |> to_string()
    stream_name = Keyword.fetch!(opts, :stream_name)
    consumer_mode = Keyword.get(opts, :consumer_mode)

    quote do
      use Dobro.App.EventHandler,
        stream_name: unquote(stream_name),
        consumer_mode: unquote(consumer_mode)

      import Dobro.App.Projector.ProjectionHelpers

      def handle(%{} = event) do
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
    Projection version schema.

    `partition_key` scopes the last-seen version to an aggregate instance (or
    event id) so create-only aggregates on a shared module stream do not collide.
    """
    use TypedEctoSchema

    @primary_key false

    typed_schema "projection_versions" do
      field :projection_name, :string, primary_key: true
      field :stream_name, :string, primary_key: true
      field :partition_key, :string, primary_key: true, default: ""
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
    alias Dobro.App.Projector.ProjectionVersion

    # @todo: make this configurable
    @timeout 5000

    def notify_projection_updated(module, projection_name, event) do
      message =
        {:projection_updated, projection_name, event.message_identity.causation_id, event.version}

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
      partition_key = partition_key(event)

      projection_version = %ProjectionVersion{
        projection_name: projection_name,
        stream_name: stream_name,
        partition_key: partition_key,
        last_seen_event_number: event_number
      }

      # @todo: make this configurable
      prefix = "projections"

      update_projection_version =
        update_projection_version_query(
          projection_name,
          stream_name,
          partition_key,
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

    @doc false
    def partition_key(%{payload: %{id: id}}) when not is_nil(id), do: to_string(id)

    def partition_key(%{message_identity: %{id: id}}) when not is_nil(id), do: to_string(id)

    def partition_key(_), do: ""

    defp update_projection_version_query(
           projection_name,
           stream_name,
           partition_key,
           event_number
         ) do
      from(pv in ProjectionVersion,
        where:
          pv.projection_name == ^projection_name and pv.stream_name == ^stream_name and
            pv.partition_key == ^partition_key and pv.last_seen_event_number < ^event_number,
        update: [set: [last_seen_event_number: ^event_number]]
      )
    end

    defp notify_and_ok(module, projection_name, event) do
      notify_projection_updated(module, projection_name, event)
      :ok
    end
  end
end
