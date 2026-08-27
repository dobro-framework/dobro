defmodule Dobro.App.QueryHandler.Pipeline do
  @moduledoc """
  Pipeline entry points and repo execution for query handlers.
  """

  alias Dobro.App.DataTransfer.DTO
  alias Dobro.App.ExecutionContext
  alias Dobro.App.QueryHandler.State
  alias Dobro.App.Scope
  alias Dobro.App.ScopePolicy
  alias Dobro.Infra.Data.ReadRepo
  alias Dobro.Pipeline
  alias Dobro.Tenant

  import Dobro.Pipeline

  @doc "Initialises a query-handler pipeline from the input query struct."
  def pipeline(%_{} = query) do
    state = %State{}
    Pipeline.new(state: state, input: query, config: %{})
  end

  @doc "Initialises a query-handler pipeline with execution context."
  def pipeline(%_{} = query, %ExecutionContext{} = execution_context) do
    state = %State{}

    Pipeline.new(
      state: state,
      input: query,
      config: %{execution_context: execution_context}
    )
    |> setup_scope()
  end

  @doc "Validates query scope and stores a `ScopeContext` on the pipeline config."
  def setup_scope(%Pipeline{} = pipeline) do
    execution_context = Map.get(pipeline.config, :execution_context, %ExecutionContext{})
    scope_context = Scope.setup_for_query!(pipeline.input, execution_context)

    case Tenant.normalize(scope_context.tenant) do
      {:ok, tenant} ->
        scope_context = %{scope_context | tenant: tenant}

        pipeline
        |> put_in([Access.key(:config), Access.key(:scope_context)], scope_context)
        |> put_in([Access.key(:config), Access.key(:tenant)], tenant)

      {:error, reason} ->
        raise Scope.Error, message: normalize_error_message(reason)
    end
  end

  defp normalize_error_message(%Dobro.Error{reason: _reason, description: description})
       when is_binary(description) and description != "" do
    description
  end

  defp normalize_error_message(%Dobro.Error{reason: reason}), do: to_string(reason)
  defp normalize_error_message(reason) when is_binary(reason), do: reason
  defp normalize_error_message(reason), do: inspect(reason)

  def put_result(pipeline, result) do
    put_in(pipeline.state.result, result)
  end

  def put_in_workspace(pipeline, key, value) do
    put_in(pipeline.state.workspace[key], value)
  end

  def get_from_workspace(pipeline, key) do
    pipeline.state.workspace[key]
  end

  @doc "Invokes a read-repo function and stores the result on the pipeline."
  def call(%Pipeline{} = pipeline, repo_fn, default_repo, opts \\ []) do
    as = Keyword.get(opts, :as)
    repo = Keyword.get(opts, :repo, default_repo)

    bind(pipeline, fn pipeline ->
      repo_args = build_repo_args(pipeline, repo, repo_fn)

      do_call(pipeline, repo_fn, as, repo, repo_args)
    end)
  end

  defp build_repo_args(
         %Pipeline{config: %{execution_context: execution_context} = config} = pipeline,
         repo,
         repo_fn
       ) do
    Code.ensure_loaded(repo)
    maybe_validate_scope!(config, repo)
    ensure_repo_fn_exists!(repo, repo_fn, repo_context_mode(repo))

    case repo_context_mode(repo) do
      :tenant ->
        [
          query_dto(pipeline),
          repo_context!(execution_context, config)
        ]

      :none ->
        args = [query_dto(pipeline)]

        if function_exported?(repo, repo_fn, 2) and selection_context?(execution_context) do
          args ++ [repo_context(execution_context, config)]
        else
          args
        end
    end
  end

  defp build_repo_args(%Pipeline{} = pipeline, repo, repo_fn) do
    Code.ensure_loaded(repo)
    maybe_validate_scope!(pipeline.config, repo)
    ensure_repo_fn_exists!(repo, repo_fn, :none)

    case repo_context_mode(repo) do
      :tenant ->
        raise("Repository function #{inspect(repo)}.#{repo_fn}/2 requires an execution context")

      :none ->
        [Map.from_struct(pipeline.input)]
    end
  end

  defp repo_context_mode(repo) do
    if function_exported?(repo, :context_mode, 0), do: repo.context_mode(), else: :none
  end

  defp scope_tenant!(%{scope_context: %{tenant: tenant}}) when not is_nil(tenant), do: tenant

  defp scope_tenant!(_config) do
    raise "Tenant context is required for tenant-scoped repository access"
  end

  defp ensure_repo_fn_exists!(repo, repo_fn, :tenant) do
    unless function_exported?(repo, repo_fn, 2) do
      raise(
        "Repository function #{inspect(repo)}.#{repo_fn}/2 is required for tenant context mode"
      )
    end
  end

  defp ensure_repo_fn_exists!(repo, repo_fn, :none) do
    unless function_exported?(repo, repo_fn, 1) or function_exported?(repo, repo_fn, 2) do
      raise(
        "Repository function #{inspect(repo)}.#{repo_fn}/1 or /2 is required for global context mode"
      )
    end
  end

  defp query_dto(pipeline) do
    pipeline.input
    |> DTO.to_dto()
  end

  defp repo_context!(%ExecutionContext{} = execution_context, config) do
    ReadRepo.Context.new(
      tenant: scope_tenant!(config),
      selection: execution_context.selection
    )
  end

  defp repo_context(%ExecutionContext{} = execution_context, config) do
    ReadRepo.Context.new(
      tenant: scope_tenant(config),
      selection: execution_context.selection
    )
  end

  defp scope_tenant(%{scope_context: %{tenant: tenant}}), do: tenant
  defp scope_tenant(_), do: nil

  defp selection_context?(%ExecutionContext{selection: selection}) when not is_nil(selection), do: true
  defp selection_context?(_), do: false

  defp maybe_validate_scope!(%{scope_context: scope_context}, repo)
       when not is_nil(scope_context) do
    ScopePolicy.validate!(scope_context, repo)
  end

  defp maybe_validate_scope!(_config, _repo), do: :ok

  defp do_call(%Pipeline{} = pipeline, repo_fn, as, repo, repo_args) do
    case repo |> apply(repo_fn, repo_args) do
      {:ok, result} ->
        if as, do: put_in_workspace(pipeline, as, result), else: put_result(pipeline, result)

      {:error, errors} when is_list(errors) ->
        merge_errors(pipeline, errors)

      {:error, error} ->
        add_error(pipeline, error)

      result ->
        if as, do: put_in_workspace(pipeline, as, result), else: put_result(pipeline, result)
    end
  end
end
