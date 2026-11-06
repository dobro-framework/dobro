defmodule Dobro.Runtime.Integration.Delivery do
  @moduledoc """
  Runs one handler invocation in the ack mode the handler declared.

  The transport supplies `transaction/1` and `advance/0`. `:with_work` calls
  `handle/1` inside that transaction, so a failure rolls the cursor back with
  the handler's writes. `:after_success` calls `handle/1` with no transaction
  open and moves the cursor only after `:ok`.

  Handlers (including projectors) may return deferred after-commit effects:

      :ok
      {:ok, after_commit: fun | [fun]}
      {:error, reason}

  Those zero-arity functions run only after a successful commit. Prefer that
  over process-dictionary stashes for Absinthe / PubSub publishes.
  """

  @default_timeout 5_000
  @max_failures 5

  @spec run(module(), map(), keyword()) :: :ok | {:error, term()} | {:dead_letter, term()}
  def run(handler, event, opts) do
    ack = ack(handler)

    case ack do
      :with_work -> with_work(handler, event, opts)
      :after_success -> after_success(handler, event, opts)
    end
  end

  @spec ack(module()) :: :with_work | :after_success
  def ack(handler) do
    if function_exported?(handler, :__ack__, 0), do: handler.__ack__(), else: :with_work
  end

  defp with_work(handler, event, opts) do
    transaction = Keyword.fetch!(opts, :transaction)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    result =
      transaction.(fn ->
        case normalize_handle_result(handler.handle(to_handler_event(event))) do
          {:ok, effects} ->
            Keyword.fetch!(opts, :advance).()
            {:ok, effects}

          {:error, reason} ->
            {:error, reason}
        end
      end, timeout: timeout)

    case result do
      {:ok, {:ok, effects}} ->
        run_after_commit(handler, event, effects)
        :ok

      {:ok, {:error, reason}} ->
        fail(handler, event, reason, opts)

      {:error, reason} ->
        fail(handler, event, reason, opts)
    end
  end

  defp after_success(handler, event, opts) do
    case normalize_handle_result(handler.handle(to_handler_event(event))) do
      {:ok, effects} ->
        transaction = Keyword.fetch!(opts, :transaction)

        case transaction.(fn -> Keyword.fetch!(opts, :advance).() end, timeout: @default_timeout) do
          {:ok, :ok} ->
            run_after_commit(handler, event, effects)
            :ok

          {:ok, _} ->
            run_after_commit(handler, event, effects)
            :ok

          {:error, reason} ->
            fail(handler, event, reason, opts)
        end

      {:error, reason} ->
        fail(handler, event, reason, opts)
    end
  end

  defp fail(_handler, event, reason, opts) do
    record = Keyword.get(opts, :record_failure, fn _ -> 1 end)
    count = record.(reason)

    if count >= Keyword.get(opts, :max_failures, @max_failures) do
      dead_letter = Keyword.get(opts, :dead_letter, fn _, _ -> :ok end)
      dead_letter.(event, reason)
      Keyword.fetch!(opts, :advance).()
      {:dead_letter, reason}
    else
      {:error, reason}
    end
  end

  defp normalize_handle_result(:ok), do: {:ok, []}

  defp normalize_handle_result({:ok, after_commit: effects}), do: {:ok, List.wrap(effects)}

  defp normalize_handle_result({:ok, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts |> Keyword.get(:after_commit, []) |> List.wrap()}
    else
      {:ok, []}
    end
  end

  defp normalize_handle_result({:ok, _}), do: {:ok, []}
  defp normalize_handle_result({:error, _} = error), do: error

  defp normalize_handle_result(other),
    do: {:error, {:unexpected_handle_result, other}}

  # Best-effort and at most once: nothing records that effects ran. Use them for
  # notifications such as Absinthe publishes, never for state changes.
  defp run_after_commit(handler, event, effects) do
    Enum.each(List.wrap(effects), &run_effect/1)

    if function_exported?(handler, :after_commit, 1) do
      handler.after_commit(to_handler_event(event))
    end

    :ok
  end

  defp run_effect(fun) when is_function(fun, 0), do: fun.()
  defp run_effect(_), do: :ok

  defp to_handler_event(%{__struct__: _} = event), do: event
  defp to_handler_event(event) when is_map(event), do: event
end
