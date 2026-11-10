defmodule Dobro.App.IntegrationEventPublisher do
  @moduledoc """
  Domain event handler that publishes integration events.

  One module covers a bounded context. `topic` and `subject_type` on `use`
  are BC defaults. Each `publish` clause sets `stream_name`, `subject_id`,
  and optionally overrides `topic`, `subject_type`, or `name`. A clause with
  no `transform` re-casts the domain payload. `transform` receives the domain
  payload and returns the public map.

  Event names default to the underscored last segment of the event module
  (`CaseStatusTransitioned` → `case_status_transitioned`). The routing key is
  `topic.event_name` (for example `funeral_planning.case_status_transitioned`).

  After the transform, atom values in the public map are stored as strings,
  including atoms nested in maps and lists. `true`, `false`, and `nil` stay
  booleans and null. Map keys are left as atoms; the outbox dump stringifies them.

  The generated handler keeps one subscription per source stream.
  """

  alias Dobro.Integration.Pattern

  defmacro __using__(opts \\ []) do
    quote do
      use Dobro.Spec.Adapter, port: Dobro.Ports.EventHandler
      import Dobro.App.IntegrationEventPublisher, only: [publish: 1, publish: 2]
      @before_compile Dobro.App.IntegrationEventPublisher
      Module.register_attribute(__MODULE__, :integration_clauses, accumulate: true)
      @integration_defaults unquote(opts)
      def __ack__, do: :with_work
    end
  end

  @doc """
  Publishes `event_module` when that domain event is delivered.

  Options: `:stream_name`, `:topic`, `:subject_type`, `:subject_id`, `:name`,
  `:transform`.
  """
  defmacro publish(event_module) do
    quote do
      publish(unquote(event_module), [])
    end
  end

  defmacro publish(event_module, opts) do
    transform = Keyword.get(opts, :transform)
    meta = Keyword.delete(opts, :transform)

    quote do
      @integration_clauses {unquote(event_module), unquote(Macro.escape(meta))}

      def handle(%unquote(event_module){} = event) do
        event
        |> unquote(__MODULE__).build(
          unquote(Macro.escape(meta)),
          @integration_defaults,
          unquote(transform)
        )
        |> Dobro.Integration.publish()
      end
    end
  end

  defmacro __before_compile__(env) do
    clauses = Module.get_attribute(env.module, :integration_clauses) || []
    defaults = Module.get_attribute(env.module, :integration_defaults) || []

    streams =
      Enum.map(clauses, fn {_event, meta} ->
        Keyword.get(meta, :stream_name) || Keyword.get(defaults, :stream_name)
      end)

    events =
      Enum.map(clauses, fn {event_module, meta} ->
        opts = Keyword.merge(defaults, meta)
        topic = Keyword.fetch!(opts, :topic)
        name = Keyword.get(opts, :name) || default_event_name(event_module)

        %{
          routing_key: Pattern.routing_key(topic, name),
          subject_type: Keyword.get(opts, :subject_type),
          stream_name: Keyword.get(opts, :stream_name),
          topic: topic,
          event_name: name
        }
      end)

    quote do
      def handle(_event), do: :ok

      def __stream_names__ do
        Enum.uniq(unquote(streams))
      end

      def __stream_name__ do
        case __stream_names__() do
          [stream | _] -> stream
          [] -> nil
        end
      end

      def __integration_events__, do: unquote(Macro.escape(events))
    end
  end

  @doc false
  def build(event, meta, defaults, transform) do
    opts = Keyword.merge(defaults, meta)

    payload =
      event.payload
      |> transform_payload(transform)
      |> put_author(event.payload)
      |> encode_values()

    topic = Keyword.fetch!(opts, :topic)
    name = Keyword.get(opts, :name) || event_name(event)

    %{
      id: event.message_identity.id,
      topic: topic,
      event_name: name,
      payload: payload,
      causation_id: event.message_identity.id,
      partition_key: fetch_field(event.payload, Keyword.fetch!(opts, :subject_id)),
      subject_type: Keyword.fetch!(opts, :subject_type),
      subject_id: fetch_field(event.payload, Keyword.fetch!(opts, :subject_id)),
      occurred_at: Map.get(event.payload, :occurred_at)
    }
  end

  defp transform_payload(payload, nil) do
    payload
    |> Map.from_struct()
    |> Map.drop([:__struct__])
  end

  defp transform_payload(payload, transform) when is_function(transform, 1) do
    case transform.(payload) do
      map when is_map(map) -> map
    end
  end

  # Completers (tasks) attribute work to the user who caused the domain event.
  defp put_author(payload, domain_payload) when is_map(payload) and is_map(domain_payload) do
    case Map.get(domain_payload, :author_user_id) || Map.get(domain_payload, "author_user_id") do
      nil -> payload
      id -> Map.put_new(payload, :author_user_id, id)
    end
  end

  defp put_author(payload, _), do: payload

  # Enum members are bare atoms. The bus stores them as strings.
  defp encode_values(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {key, encode_values(value)} end)
  end

  defp encode_values(list) when is_list(list) do
    Enum.map(list, &encode_values/1)
  end

  defp encode_values(value) when value in [nil, true, false], do: value
  defp encode_values(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_values(value), do: value

  defp event_name(%{__struct__: module}), do: default_event_name(module)

  defp default_event_name(module) when is_atom(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp fetch_field(payload, field) when is_atom(field) do
    Map.get(payload, field)
  end
end
