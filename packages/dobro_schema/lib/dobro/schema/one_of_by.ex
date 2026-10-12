defmodule Dobro.Schema.OneOfBy do
  @moduledoc """
  A value that is exactly one of several schema types, chosen by a sibling field.

  Unlike `Dobro.Schema.OneOf` (value self-describes via `discr/1`), `OneOfBy`
  resolves the member from a controller field on the parent map:

      defoneof_by ActionParams,
        types: [CreateResourceParams, SendNotificationParams],
        by: :action do
        def resolve(:create_resource), do: CreateResourceParams
        def resolve(:send_notification), do: SendNotificationParams
      end

      field :action, ActionKind, required: true
      field :params, ActionParams

  The module body must define `resolve/1`. Transports may still encode the
  payload as an exclusive-key map (e.g. GraphQL `@oneOf`); that encoding is
  mechanical — membership is decided by the controller field.
  """

  alias Dobro.Schema.OneOf

  defstruct [:of_types, :controller_field, :resolve_fn]

  @type t :: %__MODULE__{
          of_types: [module()],
          controller_field: atom(),
          resolve_fn: (term() -> module() | nil)
        }

  def new(of_types, controller_field, resolve_fn)
      when is_list(of_types) and of_types != [] and is_atom(controller_field) and
             is_function(resolve_fn, 1) do
    struct(__MODULE__, %{
      of_types: of_types,
      controller_field: controller_field,
      resolve_fn: resolve_fn
    })
  end

  @doc """
  When used without options, imports `defoneof_by/3`.

  When used with `:types`, `:by`, and `:resolve`, configures the current module
  as a OneOfBy.
  """
  defmacro __using__(opts) do
    if opts == [] do
      quote do
        import Dobro.Schema.OneOfBy, only: [defoneof_by: 3]
      end
    else
      types = Keyword.fetch!(opts, :types)
      by = Keyword.fetch!(opts, :by)
      resolve = Keyword.fetch!(opts, :resolve)

      unless is_list(types) and types != [] do
        raise ArgumentError, "Dobro.Schema.OneOfBy requires a non-empty :types list"
      end

      unless is_atom(by) do
        raise ArgumentError, "Dobro.Schema.OneOfBy requires :by to be an atom field name"
      end

      quote do
        @dobro_one_of_by_types unquote(types)
        @dobro_one_of_by_controller unquote(by)
        @dobro_one_of_by_resolve unquote(resolve)

        @doc false
        def __one_of_by_types__, do: @dobro_one_of_by_types

        @doc false
        def __one_of_by_controller__, do: @dobro_one_of_by_controller

        @doc false
        def __one_of_by__ do
          Dobro.Schema.OneOfBy.new(
            @dobro_one_of_by_types,
            @dobro_one_of_by_controller,
            @dobro_one_of_by_resolve
          )
        end

        @doc false
        def __schema__, do: []

        @doc """
        Returns the member module for a controller value, or from a member struct
        (e.g. GraphQL union `resolve_type`). Returns `nil` when unknown.
        """
        def resolve_type(%mod{}) when mod in @dobro_one_of_by_types, do: mod

        def resolve_type(controller_value) do
          type = @dobro_one_of_by_resolve.(controller_value)
          if type in @dobro_one_of_by_types, do: type, else: nil
        end
      end
    end
  end

  @doc """
  Defines a named OneOfBy module.

  The `do` block must define `resolve/1`. Additional functions (`cast/1`, `dump/1`,
  etc.) may be declared in the same block.
  """
  defmacro defoneof_by(module_name, opts, do: block) do
    types = Keyword.fetch!(opts, :types)
    by = Keyword.fetch!(opts, :by)

    unless is_list(types) and types != [] do
      raise ArgumentError, "defoneof_by requires a non-empty :types list"
    end

    unless is_atom(by) do
      raise ArgumentError, "defoneof_by requires :by to be an atom field name"
    end

    quote do
      defmodule unquote(module_name) do
        use Dobro.Schema.OneOfBy,
          types: unquote(types),
          by: unquote(by),
          resolve: &__MODULE__.resolve/1

        unquote(block)
      end
    end
  end

  @doc "True when `module` was defined with `use Dobro.Schema.OneOfBy` or `defoneof_by`."
  def one_of_by?(module) when is_atom(module) do
    match?({:module, _}, Code.ensure_compiled(module)) and
      function_exported?(module, :__one_of_by_types__, 0)
  end

  def one_of_by?(_), do: false

  @doc "Keyword list of `member_key => member_module` for exclusive-key encodings."
  def keyed_variants(%__MODULE__{of_types: types}), do: OneOf.keyed_variants(types)

  def keyed_variants(module) when is_atom(module) do
    OneOf.keyed_variants(module.__one_of_by_types__())
  end

  def keyed_variants(types) when is_list(types), do: OneOf.keyed_variants(types)

  @doc """
  Resolves the member module from a parent map using the controller field.
  """
  def resolve_member(%__MODULE__{} = one_of_by, parent) when is_map(parent) do
    controller =
      Map.get(parent, one_of_by.controller_field) ||
        Map.get(parent, Atom.to_string(one_of_by.controller_field))

    type = one_of_by.resolve_fn.(controller)

    if Enum.member?(one_of_by.of_types, type) do
      {:ok, type}
    else
      {:error, :could_not_resolve}
    end
  end

  def resolve_member(module, parent) when is_atom(module) and is_map(parent) do
    resolve_member(module.__one_of_by__(), parent)
  end
end
