defmodule Dobro.App.QueryHandler.Pipeline do
  @moduledoc """
  Query-handler pipeline: entry points, repo execution, input preparation,
  and result finalization.
  """

  alias Dobro.App.DataTransfer.DTO
  alias Dobro.App.ResultCaster
  alias Dobro.App.ExecutionContext
  alias Dobro.App.QueryHandler.State
  alias Dobro.App.Auth.GlobalContext
  alias Dobro.App.Auth.TenantContext
  alias Dobro.App.ScopePolicy
  alias Dobro.Infra.Data.ReadRepo
  alias Dobro.Pipeline
  alias Dobro.Tenant

  import Dobro.Pipeline, except: [finalize: 1, finalize: 2]

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

    case resolve_tenant(execution_context.tenant) do
      {:ok, tenant} ->
        pipeline
        |> put_in([Access.key(:config), Access.key(:tenant)], tenant)
        |> put_in(
          [Access.key(:config), Access.key(:execution_context)],
          %{execution_context | tenant: tenant}
        )

      {:error, reason} ->
        raise Dobro.App.Scope.Error, message: normalize_error_message(reason)
    end
  end

  defp resolve_tenant(nil),
    do: {:error, Dobro.Error.new(:tenant_required, description: "Tenant context is required")}

  defp resolve_tenant(%GlobalContext{} = tenant), do: {:ok, tenant}
  defp resolve_tenant(%TenantContext{} = tenant), do: Tenant.normalize(tenant)

  defp resolve_tenant(_tenant),
    do: {:error, Dobro.Error.new(:tenant_required, description: "Tenant context is required")}

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

  defp scope_tenant!(%{tenant: tenant}) when not is_nil(tenant), do: tenant

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

  defp scope_tenant(%{tenant: tenant}), do: tenant
  defp scope_tenant(_), do: nil

  defp selection_context?(%ExecutionContext{selection: selection}) when not is_nil(selection), do: true
  defp selection_context?(_), do: false

  defp maybe_validate_scope!(%{tenant: tenant}, repo) when not is_nil(tenant) do
    ScopePolicy.validate_context!(tenant, repo)
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

  @doc "Converts a handler result to DTOs when successful."
  def emit({:ok, result}), do: {:ok, DTO.to_dto(result)}
  def emit({:error, result}), do: {:error, result}
  def emit(result), do: result

  @doc """
  Finalizes a query pipeline and casts the payload to the query's `result` type.
  """
  def finalize(%Pipeline{input: %mod{}} = pipeline, :result) do
    case Pipeline.finalize(pipeline, :result) do
      {:ok, result} -> ResultCaster.cast_message_result(mod, result)
      other -> other
    end
  end

  def finalize(%Pipeline{} = pipeline, keys), do: Pipeline.finalize(pipeline, keys)
  def finalize(%Pipeline{} = pipeline), do: Pipeline.finalize(pipeline)

  @doc "Enriches query input with values from the execution context."
  def prepare_input(%_{} = input, provide, context) do
    prepare_input(Map.from_struct(input), provide, context)
  end

  def prepare_input(%{} = input, provide, _context) when provide == [] do
    input
  end

  def prepare_input(%{} = input, provide, context) do
    provide
    |> Enum.reduce(input, fn
      :tenant_id, acc -> Map.put(acc, :tenant_id, context.tenant.id)
      :tenant_identifier, acc -> Map.put(acc, :tenant_identifier, context.tenant.identifier)
      key, _ -> raise "Cannot provide: #{key}"
    end)
  end
end
