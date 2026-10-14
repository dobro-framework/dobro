defmodule Dobro.State do
  @moduledoc """
  Provides a pipeline for managing state
  """
  alias Dobro.Error
  alias Dobro.Schema.{ListOf, NonNull, OneOf, OneOfBy, OneOfInput, Types, Validations}
  import Dobro.Pipeline
  # @todo: move to domain layer
  alias Dobro.Schema.DomainValue

  defmacro changed?(field) do
    quote do
      {:changed, unquote(field)}
    end
  end

  def mutable_fields(%{} = pipeline) do
    pipeline.config.schema_module.__schema__()
    |> Enum.filter(fn {_field, {_type, opts}} ->
      not Keyword.get(opts, :immutable, false)
    end)
    |> Enum.map(fn {field, _} -> field end)
  end

  def assign_all(%{} = pipeline) do
    mutable_fields(pipeline)
    |> Enum.reduce(pipeline, &assign(&2, &1))
  end

  def assign(%{} = pipeline, fields) when is_list(fields) do
    Enum.reduce(fields, pipeline, &assign(&2, &1))
  end

  def assign(%{} = pipeline, field, opts \\ []) when is_atom(field) do
    {type, schema_opts} = pipeline.config.schema_module.__schema__!(field)
    opts = Keyword.merge(schema_opts, opts)

    if Keyword.get(opts, :immutable, false) do
      add_error(pipeline, Error.new(:immutable, path: field))
    else
      assign_field(pipeline, field, type, opts)
    end
  end

  def assign_field(%{input: input} = pipeline, field, %ListOf{of_type: of_type}, opts) do
    # Missing and nil both mean "no list" for optional fields (VO structs often
    # carry nil for unset list_of attrs). Required empty lists still error below.
    value =
      case Map.get(input, field, []) do
        nil -> []
        other -> other
      end

    opts = Keyword.merge(opts, accumulate: true)

    # Initialise value to an empty list
    pipeline = put_in(pipeline.state.value[field], [])

    cond do
      not is_list(value) ->
        add_error(pipeline, Error.new(:must_be_list, path: field))

      Keyword.get(opts, :required, false) and value == [] ->
        add_error(pipeline, Error.new(:required, path: field, description: "#{field} is required"))

      true ->
        reduce_list_field(pipeline, value, field, of_type, opts)
    end
  end

  def assign_field(%{input: input} = pipeline, field, type, opts)
      when (is_atom(type) or is_struct(type)) and is_list(opts) do
    value = Map.get(input, field)
    apply_field_value(pipeline, value, field, type, opts)
  end

  def validate(%{} = pipeline, specs) when is_list(specs) do
    Enum.reduce(specs, pipeline, &validate_field(&2, &1))
  end

  defp validate_field(pipeline, {field, {type, opts}}) do
    validate(pipeline, field, type, opts)
  end

  def validate(%{} = pipeline, field, %ListOf{of_type: of_type}, opts) do
    bind(pipeline, fn pipeline ->
      value =
        case Map.get(pipeline.state.value, field) do
          nil -> []
          other -> other
        end

      cond do
        not is_list(value) ->
          add_error(pipeline, Error.new(:must_be_list, path: field))

        Keyword.get(opts, :required, false) and value == [] ->
          add_error(pipeline, Error.new(:required, path: field, description: "#{field} is required"))

        true ->
          reduce_list_validation(pipeline, value, field, of_type, opts)
      end
    end)
  end

  def validate(%{} = pipeline, field, %NonNull{of_type: of_type}, opts) do
    validate(pipeline, field, of_type, opts)
  end

  def validate(%{} = pipeline, field, type, opts) do
    bind(pipeline, fn pipeline ->
      value = Map.get(pipeline.state.value, field)
      validate_field_value(pipeline, value, field, type, opts)
    end)
  end

  # Missing or empty
  def apply_field_value(%{} = pipeline, value, field, %NonNull{of_type: of_type}, opts) do
    if null_value?(value) do
      merge_accumulated_errors(
        pipeline,
        field,
        opts,
        [Error.new(:required, path: field, description: "#{field} is required")]
      )
    else
      cast_field_value(pipeline, of_type, value, field, opts)
    end
  end

  def apply_field_value(%{} = pipeline, value, field, _type, opts)
      when is_nil(value) or (is_binary(value) and value == "") or
             (is_list(value) and value == []) do
    if Keyword.get(opts, :required, false) do
      error = Error.new(:required, path: field, description: "#{field} is required")
      add_error(pipeline, error)
    else
      pipeline
    end
  end

  def apply_field_value(
        %{} = pipeline,
        value,
        field,
        %OneOf{of_types: of_types, discr_fn: discr_fn} = one_of,
        opts
      ) do
    apply_one_of(pipeline, value, field, one_of, of_types, discr_fn, opts)
  end

  def apply_field_value(%{} = pipeline, value, field, %OneOfBy{} = one_of_by, opts) do
    apply_one_of_by(pipeline, value, field, one_of_by, opts)
  end

  def apply_field_value(%{} = pipeline, value, field, %OneOfInput{} = one_of_input, opts) do
    # Legacy keyed schema type: store the unwrapped cast member.
    apply_keyed_one_of(pipeline, value, field, one_of_input.variants, opts)
  end

  def apply_field_value(%{} = pipeline, value, field, type, opts)
      when is_atom(type) and not is_nil(type) do
    cond do
      OneOf.one_of?(type) ->
        %OneOf{of_types: of_types, discr_fn: discr_fn} = one_of = type.__one_of__()
        apply_one_of(pipeline, value, field, one_of, of_types, discr_fn, opts)

      OneOfBy.one_of_by?(type) ->
        apply_one_of_by(pipeline, value, field, type.__one_of_by__(), opts)

      one_of_input_module?(type) ->
        apply_keyed_one_of(pipeline, value, field, type.__one_of_input__().variants, opts)

      true ->
        cast_field_value(pipeline, type, value, field, opts)
    end
  end

  def apply_field_value(%{} = pipeline, value, field, type, opts) do
    cast_field_value(pipeline, type, value, field, opts)
  end

  # Keyed exclusive envelope (e.g. GraphQL @oneOf) first; otherwise discr_fn.
  defp apply_one_of(pipeline, value, field, _one_of, of_types, discr_fn, opts) do
    variants = OneOf.keyed_variants(of_types)

    case OneOfInput.unwrap(OneOfInput.new(variants), value) do
      {:ok, {_name, variant_value}} ->
        cast_discriminated_member(pipeline, variant_value, field, of_types, discr_fn, opts)

      {:error, :one_of_exclusive} ->
        add_error(
          pipeline,
          Error.new(:one_of_exclusive,
            path: field,
            description: "#{field} allows exactly one variant"
          )
        )

      {:error, :one_of_required} ->
        cast_discriminated_member(pipeline, value, field, of_types, discr_fn, opts)
    end
  end

  # Sibling-field discr: unwrap keyed envelope for payload, resolve member via parent.
  defp apply_one_of_by(pipeline, value, field, %OneOfBy{} = one_of_by, opts) do
    variants = OneOfBy.keyed_variants(one_of_by)
    parent = parent_for_one_of_by(pipeline)

    case OneOfInput.unwrap(OneOfInput.new(variants), value) do
      {:ok, {_name, variant_value}} ->
        cast_one_of_by_member(pipeline, variant_value, field, one_of_by, parent, opts)

      {:error, :one_of_exclusive} ->
        add_error(
          pipeline,
          Error.new(:one_of_exclusive,
            path: field,
            description: "#{field} allows exactly one variant"
          )
        )

      {:error, :one_of_required} ->
        cast_one_of_by_member(pipeline, value, field, one_of_by, parent, opts)
    end
  end

  # Prefer already-cast state values; keep input for not-yet-assigned (nil) siblings
  # so controller fields declared before this OneOfBy still resolve during assign_all.
  defp parent_for_one_of_by(pipeline) do
    input = pipeline.input || %{}
    state = pipeline.state.value || %{}

    Map.merge(input, Map.reject(state, fn {_key, value} -> is_nil(value) end))
  end

  defp cast_one_of_by_member(pipeline, value, field, one_of_by, parent, opts) do
    case OneOfBy.resolve_member(one_of_by, parent) do
      {:ok, of_type} ->
        cast_field_value(pipeline, of_type, value, field, opts)

      {:error, _} ->
        add_error(
          pipeline,
          Error.new(:could_not_assign,
            path: field,
            description: "#{field} could not resolve member from #{one_of_by.controller_field}"
          )
        )
    end
  end

  defp cast_discriminated_member(pipeline, value, field, of_types, discr_fn, opts) do
    of_type = discr_fn.(value)

    if Enum.member?(of_types, of_type) do
      cast_field_value(pipeline, of_type, value, field, opts)
    else
      apply_keyed_one_of(pipeline, value, field, OneOf.keyed_variants(of_types), opts)
    end
  end

  defp apply_keyed_one_of(pipeline, value, field, variants, opts) do
    case unwrap_or_resolve_member(variants, value) do
      {:ok, {_name, variant_type, variant_value}} ->
        case cast_one_of_variant(variant_type, variant_value) do
          {:ok, casted} ->
            put_in(pipeline.state.value, Map.put(pipeline.state.value, field, casted))

          {:error, errors} when is_list(errors) ->
            merge_accumulated_errors(pipeline, field, opts, errors)

          {:error, reason} ->
            add_error(
              pipeline,
              Error.new(reason, path: field, description: "invalid one_of variant")
            )
        end

      {:error, :one_of_required} ->
        if Keyword.get(opts, :required, false) do
          add_error(
            pipeline,
            Error.new(:required, path: field, description: "#{field} requires exactly one variant")
          )
        else
          pipeline
        end

      {:error, :one_of_exclusive} ->
        add_error(
          pipeline,
          Error.new(:one_of_exclusive,
            path: field,
            description: "#{field} allows exactly one variant"
          )
        )

      {:error, :could_not_assign} ->
        add_error(pipeline, Error.new(:could_not_assign, path: field))
    end
  end

  defp unwrap_or_resolve_member(variants, value) do
    case OneOfInput.unwrap(OneOfInput.new(variants), value) do
      {:ok, {name, variant_value}} ->
        {:ok, {name, Keyword.fetch!(variants, name), variant_value}}

      {:error, :one_of_exclusive} = err ->
        err

      {:error, :one_of_required} ->
        resolve_untagged_member(variants, value)
    end
  end

  defp resolve_untagged_member(variants, %{__struct__: mod} = value) do
    case Enum.find(variants, fn {_name, type} -> type == mod end) do
      {name, type} -> {:ok, {name, type, value}}
      nil -> {:error, :could_not_assign}
    end
  end

  defp resolve_untagged_member(variants, value) when is_map(value) do
    variants
    |> Enum.find_value(fn {name, type} ->
      case cast_one_of_variant(type, value) do
        {:ok, casted} -> {:ok, {name, type, casted}}
        _ -> nil
      end
    end)
    |> case do
      {:ok, _} = ok -> ok
      nil -> {:error, :one_of_required}
    end
  end

  defp resolve_untagged_member(_variants, _), do: {:error, :one_of_required}

  defp one_of_input_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__one_of_input__, 0)
  end

  defp cast_one_of_variant(type, value) when is_atom(type) do
    cond do
      Types.type_exists?(type) ->
        {:ok, Types.type_module(type).new(value)}

      function_exported?(type, :new, 1) ->
        type.new(value)

      true ->
        {:ok, value}
    end
  end

  defp cast_one_of_variant(_type, value), do: {:ok, value}

  def cast_field_value(%{} = pipeline, type, value, field, opts) do
    if Types.type_exists?(type) do
      value = Types.type_module(type).new(value)
      apply_primitive(pipeline, value, field, type, opts)
    else
      apply_value_object(pipeline, value, field, type, opts)
    end
  end

  defp validate_field_value(%{} = pipeline, value, field, _type, opts)
       when is_nil(value) or (is_binary(value) and value == "") or
              (is_list(value) and value == []) do
    if Keyword.get(opts, :required, false) do
      error = Error.new(:required, path: field, description: "#{field} is required")
      add_error(pipeline, error)
    else
      pipeline
    end
  end

  defp validate_field_value(%{} = pipeline, value, field, type, opts) do
    validators = Keyword.get(opts, :validate, [])

    case Validations.validate_attr(value, field, type, validators) do
      :ok ->
        pipeline

      {:error, errors} ->
        merge_errors(pipeline, errors)
    end
  end

  defp apply_primitive(%{} = pipeline, value, field, type, opts) do
    validators = Keyword.get(opts, :validate, [])
    accumulate = Keyword.get(opts, :accumulate, false)

    case Validations.validate_attr(value, field, type, validators) do
      :ok ->
        value =
          if accumulate do
            items = pipeline.state.value[field] || []
            Map.put(pipeline.state.value, field, items ++ [value])
          else
            Map.put(pipeline.state.value, field, value)
          end

        put_in(pipeline.state.value, value)

      {:error, errors} ->
        merge_accumulated_errors(pipeline, field, opts, errors)
    end
  end

  defp apply_value_object(%{} = pipeline, value, field, type, opts) do
    accumulate = Keyword.get(opts, :accumulate, false)

    case type.new(value) do
      {:ok, vo_state} ->
        put_value_object_state(pipeline, field, vo_state, accumulate)

      {:error, errors} ->
        merge_value_object_errors(pipeline, field, type, errors, accumulate)
    end
  end

  def precondition(%{} = pipeline, fun) do
    bind(pipeline, fn pipeline ->
      case fun.(pipeline.state) do
        :ok -> pipeline
        {:error, error} -> add_error(pipeline, error)
      end
    end)
  end

  def put_in_value(%{} = pipeline, field, value) do
    put_in(pipeline.state.value, Map.put(pipeline.state.value, field, value))
  end

  # @todo: check intersection

  @doc """
  Hydrates the pipeline with the given fields
  Like assign, but runs no validations, preconditions including for Value Objects
  To be used when deserialising from events
  """
  def hydrate(%{} = pipeline, fields) when is_list(fields) do
    bind(pipeline, fn pipeline ->
      schema_module = pipeline.config.schema_module

      fields
      |> Enum.reduce(pipeline, &hydrate_field(&2, schema_module, &1))
    end)
  end

  @doc """
  Hydrates the pipeline with all fields
  Like hydrate, but runs no validations, preconditions including for Value Objects
  To be used when deserialising from events
  """
  def hydrate_all(%{} = pipeline) do
    schema_module = pipeline.config.schema_module

    fields = schema_module.__schema__() |> Enum.map(fn {field, _} -> field end)
    hydrate(pipeline, fields)
  end

  defp reduce_list_field(pipeline, values, field, of_type, opts) do
    Enum.reduce(values, pipeline, fn value, pipeline ->
      apply_field_value(pipeline, value, field, of_type, opts)
    end)
  end

  defp reduce_list_validation(pipeline, values, field, of_type, opts) do
    Enum.reduce(values, pipeline, fn item, pipeline ->
      validate_field_value(pipeline, item, field, of_type, opts)
    end)
  end

  defp put_value_object_state(pipeline, field, vo_state, accumulate) do
    value =
      if accumulate do
        items = pipeline.state.value[field] || []
        Map.put(pipeline.state.value, field, items ++ [vo_state])
      else
        Map.put(pipeline.state.value, field, vo_state)
      end

    put_in(pipeline.state.value, value)
  end

  defp merge_value_object_errors(pipeline, field, type, errors, accumulate) do
    index = if accumulate, do: length(pipeline.state.value[field] || []), else: nil
    path_prefix = if index, do: "#{field}[#{index}]", else: to_string(field)

    if singular_value_object?(type) do
      merge_errors(pipeline, Enum.map(errors, &%{&1 | path: field}))
    else
      pipeline
      |> add_error(Error.new(:invalid, path: field, description: "#{field} is invalid"))
      |> merge_errors(errors, path_prefix: path_prefix)
    end
  end

  defp singular_value_object?(type) do
    Code.ensure_loaded?(type) and function_exported?(type, :singular?, 0) and type.singular?()
  end

  defp null_value?(nil), do: true
  defp null_value?(""), do: true
  defp null_value?(_), do: false

  defp merge_accumulated_errors(pipeline, field, opts, errors) do
    if Keyword.get(opts, :accumulate, false) do
      index = length(pipeline.state.value[field] || [])
      path_prefix = "#{field}[#{index}]"

      errors =
        Enum.map(errors, fn
          %{path: ^field} = error ->
            %{error | path: path_prefix}

          error ->
            %{error | path: Enum.join([path_prefix, error.path] |> Enum.filter(& &1), ".")}
        end)

      merge_errors(pipeline, errors)
    else
      merge_errors(pipeline, errors)
    end
  end

  defp hydrate_field(pipeline, schema_module, field) do
    if Map.has_key?(pipeline.input, field) do
      {type, _} = schema_module.__schema__!(field)
      hydrate_input_field(pipeline, field, type)
    else
      pipeline
    end
  end

  defp hydrate_input_field(pipeline, field, type) do
    parent = parent_for_one_of_by(pipeline)

    case DomainValue.load(Map.get(pipeline.input, field), type, parent) do
      {:ok, value} ->
        put_in(pipeline.state.value, Map.put(pipeline.state.value, field, value))

      {:error, error} ->
        add_error(pipeline, error)
    end
  end
end
