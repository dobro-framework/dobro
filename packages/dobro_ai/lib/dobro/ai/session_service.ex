defmodule Dobro.AI.SessionService do
  @moduledoc """
  Feature-agnostic AI session operations (load, migrate, view).
  """

  alias Dobro.AI.Sessions
  alias Dobro.App.ExecutionContext

  @type session_view :: %{
          session_id: term(),
          status: String.t(),
          messages: [map()],
          value: term(),
          assigns: term(),
          question: term()
        }

  @doc """
  Loads a session owned by the current actor.
  """
  @spec get(String.t(), String.t(), ExecutionContext.t()) ::
          {:ok, session_view()} | {:error, :not_found | :actor_required}
  def get(context_type, context_key, %ExecutionContext{} = execution_context)
      when is_binary(context_type) and is_binary(context_key) do
    with {:ok, user_id} <- user_id_from(execution_context),
         {:ok, session} <- Sessions.get(context_type, context_key, user_id) do
      {:ok, session_view(session)}
    end
  end

  @doc """
  Archives the current session so the next message starts a clean conversation.
  """
  @spec start_new(String.t(), String.t(), ExecutionContext.t()) ::
          {:ok, session_view()} | {:error, :actor_required | term()}
  def start_new(context_type, context_key, %ExecutionContext{} = execution_context)
      when is_binary(context_type) and is_binary(context_key) do
    with {:ok, user_id} <- user_id_from(execution_context),
         {:ok, _} <- Sessions.start_new(context_type, context_key, user_id) do
      {:ok, empty_session_view()}
    end
  end

  @doc """
  Re-keys a session so continuity survives create → edit transitions.
  """
  @spec migrate(String.t(), String.t(), String.t(), ExecutionContext.t()) ::
          {:ok, session_view()} | {:error, :not_found | :actor_required | term()}
  def migrate(context_type, from_context_key, to_context_key, %ExecutionContext{} = execution_context)
      when is_binary(context_type) and is_binary(from_context_key) and is_binary(to_context_key) do
    with {:ok, user_id} <- user_id_from(execution_context),
         {:ok, session} <- Sessions.get(context_type, from_context_key, user_id),
         {:ok, migrated} <- Sessions.migrate_context_key(session, to_context_key) do
      {:ok, session_view(migrated)}
    end
  end

  @doc "Normalizes a persisted session into an API-friendly view."
  @spec session_view(Dobro.AI.Infra.SessionSchema.t()) :: session_view()
  def session_view(session) do
    question = get_in(session.metadata || %{}, ["last_question"])

    %{
      session_id: session.id,
      status: derived_status(session.status, question),
      messages: normalize_display_messages(Sessions.display_messages(session)),
      value: get_in(session.metadata || %{}, ["last_value"]),
      assigns: get_in(session.metadata || %{}, ["last_assigns"]) || get_in(session.metadata || %{}, ["assigns"]),
      question: question
    }
  end

  defp derived_status("running", _), do: "running"
  defp derived_status("complete", _), do: "complete"
  defp derived_status("archived", _), do: "archived"

  defp derived_status(_status, question) when is_binary(question) and question != "",
    do: "needs_input"

  defp derived_status(status, _), do: status

  @doc "Empty session view used after starting a new chat."
  @spec empty_session_view() :: session_view()
  def empty_session_view do
    %{
      session_id: nil,
      status: "active",
      messages: [],
      value: nil,
      assigns: nil,
      question: nil
    }
  end

  defp normalize_display_messages(messages) do
    Enum.map(messages, fn message ->
      %{
        role: Map.get(message, :role) || Map.get(message, "role"),
        content: Map.get(message, :content) || Map.get(message, "content")
      }
    end)
  end

  defp user_id_from(%ExecutionContext{auth_context: %{actor: %{id: id}}}) when is_integer(id),
    do: {:ok, id}

  defp user_id_from(_), do: {:error, :actor_required}
end
