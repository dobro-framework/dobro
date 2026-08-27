defmodule Dobro.AI.Sessions do
  @moduledoc """
  Generic persistence for multi-turn AI sessions.
  """

  import Ecto.Query

  alias Dobro.AI.Infra.SessionSchema
  alias Dobro.AI.ProviderContinuation
  alias Dobro.Infra.Repo

  @type session :: SessionSchema.t()

  @doc """
  Returns an existing session or creates a new one for the actor and context key.
  """
  @spec get_or_create(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, session()} | {:error, term()}
  def get_or_create(context_type, context_key, user_id, opts \\ [])
      when is_binary(context_type) and is_binary(context_key) and is_integer(user_id) do
    tenant_id = Keyword.get(opts, :tenant_id)
    metadata = Keyword.get(opts, :metadata)

    case fetch_session(user_id, context_type, context_key) do
      {:ok, session} ->
        {:ok, maybe_update_metadata(session, metadata)}

      {:error, :not_found} ->
        %SessionSchema{}
        |> SessionSchema.changeset(%{
          user_id: user_id,
          tenant_id: tenant_id,
          context_type: context_type,
          context_key: context_key,
          messages: %{},
          status: "active",
          metadata: metadata || %{}
        })
        |> Repo.insert()
    end
  end

  @doc "Returns the current (non-archived) session owned by the user, or `:not_found`."
  @spec get(String.t(), String.t(), pos_integer()) :: {:ok, session()} | {:error, :not_found}
  def get(context_type, context_key, user_id) do
    fetch_session(user_id, context_type, context_key)
  end

  @doc """
  Archives the current session for this context so the next `get_or_create/4`
  starts a clean conversation. No-ops when there is no current session.
  """
  @spec start_new(String.t(), String.t(), pos_integer()) ::
          {:ok, :started | :already_empty} | {:error, term()}
  def start_new(context_type, context_key, user_id)
      when is_binary(context_type) and is_binary(context_key) and is_integer(user_id) do
    case fetch_session(user_id, context_type, context_key) do
      {:ok, session} ->
        case archive(session) do
          {:ok, _} -> {:ok, :started}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:ok, :already_empty}
    end
  end

  @doc "Persists agent message history and optional session attrs."
  @spec save(session(), [map()], keyword()) :: {:ok, session()} | {:error, term()}
  def save(%SessionSchema{} = session, agent_messages, attrs \\ []) when is_list(agent_messages) do
    display_messages = Keyword.get(attrs, :display_messages, display_messages(session))
    metadata = Map.merge(session.metadata || %{}, Keyword.get(attrs, :metadata, %{}))
    status = Keyword.get(attrs, :status, session.status)

    session
    |> SessionSchema.changeset(%{
      messages: encode_messages(agent_messages),
      metadata: Map.put(metadata, "display_messages", display_messages),
      status: status
    })
    |> Repo.update()
  end

  @doc "Marks a session complete."
  @spec complete(session()) :: {:ok, session()} | {:error, term()}
  def complete(%SessionSchema{} = session) do
    session
    |> SessionSchema.changeset(%{status: "complete"})
    |> Repo.update()
  end

  @doc "Archives a session so it is no longer returned by get/get_or_create."
  @spec archive(session()) :: {:ok, session()} | {:error, term()}
  def archive(%SessionSchema{} = session) do
    session
    |> SessionSchema.changeset(%{status: "archived"})
    |> Repo.update()
  end

  @doc "Re-keys a session so continuity survives create → edit transitions."
  @spec migrate_context_key(session(), String.t()) :: {:ok, session()} | {:error, term()}
  def migrate_context_key(%SessionSchema{} = session, new_context_key)
      when is_binary(new_context_key) do
    case fetch_session(session.user_id, session.context_type, new_context_key) do
      {:ok, existing} ->
        {:ok, existing}

      {:error, :not_found} ->
        session
        |> SessionSchema.changeset(%{context_key: new_context_key})
        |> Repo.update()
    end
  end

  @doc "Returns stored agent messages with atom keys."
  @spec agent_messages(session()) :: [map()]
  def agent_messages(%SessionSchema{} = session) do
    session
    |> Map.get(:messages, %{})
    |> decode_messages()
  end

  @doc "Returns user-visible chat messages from session metadata."
  @spec display_messages(session()) :: [map()]
  def display_messages(%SessionSchema{} = session) do
    session
    |> get_in([Access.key(:metadata), "display_messages"])
    |> case do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "Returns the provider-side continuation handle stored on the session, if any."
  @spec provider_continuation(session()) :: ProviderContinuation.t() | nil
  def provider_continuation(%SessionSchema{} = session) do
    session
    |> get_in([Access.key(:metadata), "provider_continuation"])
    |> ProviderContinuation.from_map()
  end

  @doc "Merges a provider continuation into session metadata."
  @spec put_provider_continuation(map(), ProviderContinuation.t() | nil) :: map()
  def put_provider_continuation(metadata, continuation) when is_map(metadata) do
    case ProviderContinuation.to_map(continuation) do
      nil -> Map.delete(metadata, "provider_continuation")
      encoded -> Map.put(metadata, "provider_continuation", encoded)
    end
  end

  defp fetch_session(user_id, context_type, context_key) do
    case Repo.one(
           from(s in SessionSchema,
             where:
               s.user_id == ^user_id and s.context_type == ^context_type and
                 s.context_key == ^context_key and s.status != "archived",
             order_by: [desc: s.updated_at],
             limit: 1
           )
         ) do
      %SessionSchema{} = session -> {:ok, session}
      nil -> {:error, :not_found}
    end
  end

  defp maybe_update_metadata(%SessionSchema{} = session, nil), do: session

  defp maybe_update_metadata(%SessionSchema{} = session, metadata) when is_map(metadata) do
    case Repo.update(
           SessionSchema.changeset(session, %{
             metadata: Map.merge(session.metadata || %{}, metadata)
           })
         ) do
      {:ok, updated} -> updated
      {:error, _} -> session
    end
  end

  defp encode_messages(messages) do
    messages
    |> Enum.map(&encode_message/1)
    |> then(&%{items: &1})
  end

  defp decode_messages(%{"items" => items}) when is_list(items), do: Enum.map(items, &decode_message/1)
  defp decode_messages(%{items: items}) when is_list(items), do: Enum.map(items, &decode_message/1)
  defp decode_messages(_), do: []

  defp encode_message(message) when is_map(message) do
    message
    |> Map.new(fn {key, value} -> {to_string(key), encode_value(value)} end)
  end

  defp decode_message(message) when is_map(message) do
    message
    |> Map.new(fn {key, value} -> {decode_key(key), decode_value(value)} end)
    |> normalize_agent_message()
  end

  defp normalize_agent_message(%{} = message) do
    message
    |> Map.update(:role, nil, &normalize_role/1)
    |> Map.update(:tool_calls, nil, fn
      nil -> nil
      tool_calls when is_list(tool_calls) -> Enum.map(tool_calls, &normalize_tool_call/1)
      other -> other
    end)
  end

  defp normalize_role(role) when is_binary(role) do
    case role do
      "system" -> :system
      "user" -> :user
      "assistant" -> :assistant
      "tool" -> :tool
      other -> other
    end
  end

  defp normalize_role(role), do: role

  defp normalize_tool_call(%{} = tool_call) do
    tool_call
    |> Map.new(fn {key, value} ->
      key = decode_key(key)
      value = if key == :function and is_map(value), do: normalize_function(value), else: value
      {key, value}
    end)
  end

  defp normalize_function(%{} = function) do
    Map.new(function, fn {key, value} -> {decode_key(key), value} end)
  end

  defp encode_value(list) when is_list(list), do: Enum.map(list, &encode_message/1)
  defp encode_value(value), do: value

  defp decode_value(list) when is_list(list), do: Enum.map(list, &decode_message/1)
  defp decode_value(value), do: value

  defp decode_key(key) when is_atom(key), do: key

  defp decode_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> String.to_atom(key)
    end
  end
end
