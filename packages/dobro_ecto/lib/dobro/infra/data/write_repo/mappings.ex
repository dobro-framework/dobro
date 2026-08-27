defmodule Dobro.Infra.Data.WriteRepo.Mappings do
  @moduledoc """
  Resolves WriteRepo `:mappings` / `:mapper` options into quoted setup AST.
  """

  alias Dobro.Infra.Data.Mappings

  @doc """
  Returns `{mapper_setup_ast, preloads}` for WriteRepo opts.

  When `mappings:` is set, the write repo `use`s `Dobro.Infra.Data.Mapper` and
  defines field/association overrides on itself.

  When only `mapper:` is set, imports that module's `to_domain/2` and `to_changeset/2`.
  Otherwise imports `DefaultMapper`.
  """
  def resolve(opts, repo_module) do
    mappings = Mappings.normalize(Keyword.get(opts, :mappings))
    explicit_mapper = Keyword.get(opts, :mapper)
    preloads = Mappings.preload_names(mappings)

    cond do
      mappings.fields == %{} and mappings.associations == %{} ->
        mapper = explicit_mapper || Dobro.Infra.Data.DefaultMapper
        {import_mapper_ast(mapper), preloads}

      not is_nil(explicit_mapper) ->
        raise ArgumentError,
              "WriteRepo #{inspect(repo_module)} cannot set both :mapper and :mappings — " <>
                "use :mappings for declarative field/association maps, or :mapper for a custom module"

      true ->
        {inline_mapper_ast(mappings), preloads}
    end
  end

  defp import_mapper_ast(mapper_module) do
    quote do
      import unquote(mapper_module), only: [to_domain: 2, to_changeset: 2]
    end
  end

  defp inline_mapper_ast(mappings) do
    quote do
      use Dobro.Infra.Data.Mapper

      unquote(field_clauses(mappings.fields))
      unquote(association_clauses(mappings.associations))

      def get_from_dto(dto, key), do: super(dto, key)
      def put_in_dto(dto, key, value), do: super(dto, key, value)
    end
  end

  defp field_clauses(fields) when map_size(fields) == 0, do: nil

  defp field_clauses(fields) do
    keys = Map.keys(fields)
    escaped = Macro.escape(fields)

    quote do
      @field_mappings unquote(escaped)
      @mapped_fields unquote(keys)

      def get_from_dto(dto, key) when key in @mapped_fields do
        {:ok, Dobro.Infra.Data.Mappings.get_field(dto, key, Map.fetch!(@field_mappings, key))}
      end

      def put_in_dto(dto, key, value) when key in @mapped_fields do
        {:ok, Dobro.Infra.Data.Mappings.put_field(dto, key, value, Map.fetch!(@field_mappings, key))}
      end
    end
  end

  defp association_clauses(associations) when map_size(associations) == 0, do: nil

  defp association_clauses(associations) do
    keys = Map.keys(associations)
    escaped = Macro.escape(associations)

    quote do
      @association_mappings unquote(escaped)
      @mapped_associations unquote(keys)

      def get_from_dto(dto, key) when key in @mapped_associations do
        {:ok, Dobro.Infra.Data.Mappings.get_association(dto, Map.fetch!(@association_mappings, key))}
      end

      def put_in_dto(dto, key, value) when key in @mapped_associations do
        {:ok,
         Dobro.Infra.Data.Mappings.put_association(dto, value, Map.fetch!(@association_mappings, key))}
      end
    end
  end
end
