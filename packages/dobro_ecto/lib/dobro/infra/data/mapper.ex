defmodule Dobro.Infra.Data.Mapper do
  @moduledoc """
  Maps domain entities to their data layer representations and vice versa.

  This module provides utilities for mapping between different data structures,
  typically used for converting between domain models, data transfer objects (DTOs),
  and database entities within the infrastructure layer.

  ## Usage

  This module should be used when you need to transform data across different
  layers of the application while maintaining separation of concerns.
  """
  defmacro __using__(_opts \\ []) do
    quote do
      import Dobro.Schema.DomainValue
      alias Dobro.App.DataTransfer.DTO

      @doc """
      Converts a data transfer object (DTO) to a domain aggregate.
      """
      def to_domain(%{} = dto, aggregate_module) when is_struct(dto) do
        dto
        |> Map.from_struct()
        |> to_domain(aggregate_module)
      end

      def to_domain(%{} = dto, aggregate_module) do
        initial = %{version: dto.version}

        fields =
          aggregate_module.__schema__()
          |> Enum.reduce_while({:ok, initial}, fn {key, {type, _opts}}, {:ok, acc} ->
            with {:ok, value} <- apply(__MODULE__, :get_from_dto, [dto, key]),
                 value <- load!(value, type),
                 {:ok, acc} <- apply(__MODULE__, :put_in_domain, [acc, key, value]) do
              {:cont, {:ok, acc}}
            else
              {:error, error} ->
                {:halt, {:error, error}}
            end
          end)

        case fields do
          {:ok, fields} ->
            {:ok, struct(aggregate_module, fields)}

          {:error, error} ->
            {:error, error}
        end
      end

      @doc """
      Gets a value from a data transfer object (DTO) by key.
      """
      @spec get_from_dto(term(), atom()) :: {:ok, term()} | {:error, term()}
      def get_from_dto(dto, key) do
        {:ok, Map.get(dto, key)}
      end

      @spec put_in_dto(map(), atom(), term()) :: {:ok, map()} | {:error, term()}
      def put_in_dto(dto, key, value) do
        {:ok, dto |> Map.put(key, value)}
      end

      @spec put_in_domain(map(), atom(), term()) :: {:ok, map()} | {:error, term()}
      def put_in_domain(domain, key, value) do
        {:ok, domain |> Map.put(key, value)}
      end

      @spec get_from_domain(term(), atom()) :: {:ok, term()} | {:error, term()}
      def get_from_domain(domain, key) do
        {:ok, Map.get(domain, key)}
      end

      @spec dto_for(term()) :: {:ok, term()} | {:error, term()}
      defp dto_for(value), do: {:ok, DTO.to_dto(value)}

      @doc """
      Converts an aggregate to an Ecto changeset using the provided schema module.
      """
      def to_changeset(aggregate, schema) do
        initial = %{version: aggregate.version || 0}

        fields =
          aggregate.__struct__.__schema__()
          |> Enum.reduce_while({:ok, initial}, fn {key, {_type, _opts}}, {:ok, acc} ->
            with {:ok, value} <- apply(__MODULE__, :get_from_domain, [aggregate, key]),
                 {:ok, value} <- dto_for(value),
                 {:ok, acc} <- apply(__MODULE__, :put_in_dto, [acc, key, value]) do
              {:cont, {:ok, acc}}
            else
              {:error, error} ->
                {:halt, {:error, error}}
            end
          end)

        case fields do
          {:ok, fields} ->
            apply_changeset(schema, fields)

          {:error, error} ->
            raise "Could not build changeset: #{error}"
        end
      end

      defp apply_changeset(schema, fields) do
        case schema.__struct__.changeset(schema, fields) do
          %{errors: []} = changeset -> {:ok, changeset}
          changeset_with_errors -> {:error, errors_from_changeset(changeset_with_errors)}
        end
      end

      defp errors_from_changeset(%{errors: errors}) do
        Dobro.Error.new(
          :changeset_errors,
          description: "Changeset error fields: #{Enum.join(Keyword.keys(errors), ", ")}"
        )
      end

      defoverridable(
        to_domain: 2,
        to_changeset: 2,
        get_from_dto: 2,
        put_in_dto: 3,
        get_from_domain: 2,
        put_in_domain: 3
      )
    end
  end
end
