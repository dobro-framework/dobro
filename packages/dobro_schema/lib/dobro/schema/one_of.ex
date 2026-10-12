defmodule Dobro.Schema.OneOf do
  @moduledoc """
  A value that is exactly one of several schema types.

  ## Inline

      field :node, one_of([Leaf, Group], &MyApp.discr/1)

  ## Named (reusable type for contracts / GraphQL naming)

      defoneof DependencyNode, types: [Dependency, DependencyGroup] do
        def discr(%{operator: _}), do: DependencyGroup
        def discr(%{"operator" => _}), do: DependencyGroup
        def discr(_), do: Dependency
      end

      field :dependencies, list_of(DependencyNode)

  Or with `use` (equivalent):

      defmodule DependencyNode do
        use Dobro.Schema.OneOf,
          types: [Dependency, DependencyGroup],
          discr: &__MODULE__.discr/1

        def discr(%{operator: _}), do: DependencyGroup
        def discr(_), do: Dependency
      end

  The module body must define `discr/1`. Transports may encode a one_of as an
  exclusive-key map (e.g. GraphQL `@oneOf`). Keys are the underscored leaf module
  name (`DependencyGroup` → `:dependency_group`). That encoding is mechanical —
  not part of the Dobro type meaning.
  """

  defstruct [:of_types, :discr_fn]

  @type t :: %__MODULE__{of_types: [module()], discr_fn: (term() -> module())}

  def new(of_types, discr_fn)
      when is_list(of_types) and of_types != [] and is_function(discr_fn, 1) do
    struct(__MODULE__, %{of_types: of_types, discr_fn: discr_fn})
  end

  @doc """
  When used without options, imports `defoneof/3`.

  When used with `:types` and `:discr`, configures the current module as a OneOf.
  """
  defmacro __using__(opts) do
    if opts == [] do
      quote do
        import Dobro.Schema.OneOf, only: [defoneof: 3]
      end
    else
      types = Keyword.fetch!(opts, :types)
      discr = Keyword.fetch!(opts, :discr)

      unless is_list(types) and types != [] do
        raise ArgumentError, "Dobro.Schema.OneOf requires a non-empty :types list"
      end

      quote do
        @dobro_one_of_types unquote(types)
        @dobro_one_of_discr unquote(discr)

        @doc false
        def __one_of_types__, do: @dobro_one_of_types

        @doc false
        def __one_of__ do
          Dobro.Schema.OneOf.new(@dobro_one_of_types, @dobro_one_of_discr)
        end

        @doc false
        def __schema__, do: []

        @doc "Returns the member module for `value`, or `nil` when it does not match."
        def resolve_type(value) do
          type = @dobro_one_of_discr.(value)
          if type in @dobro_one_of_types, do: type, else: nil
        end
      end
    end
  end

  @doc """
  Defines a named OneOf module.

  The `do` block must define `discr/1`. Additional functions (`cast/1`, `dump/1`,
  etc.) may be declared in the same block.
  """
  defmacro defoneof(module_name, opts, do: block) do
    types = Keyword.fetch!(opts, :types)

    unless is_list(types) and types != [] do
      raise ArgumentError, "defoneof requires a non-empty :types list"
    end

    quote do
      defmodule unquote(module_name) do
        use Dobro.Schema.OneOf,
          types: unquote(types),
          discr: &__MODULE__.discr/1

        unquote(block)
      end
    end
  end

  @doc "True when `module` was defined with `use Dobro.Schema.OneOf` or `defoneof`."
  def one_of?(module) when is_atom(module) do
    match?({:module, _}, Code.ensure_compiled(module)) and
      function_exported?(module, :__one_of_types__, 0)
  end

  def one_of?(_), do: false

  @doc """
  Mechanical key for exclusive-key encodings of a member module.

  Underscored leaf name only: `Foo.Bar.DependencyGroup` → `:dependency_group`.
  """
  def member_key(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  @doc "Keyword list of `member_key => member_module` for exclusive-key encodings."
  def keyed_variants(%__MODULE__{of_types: types}), do: keyed_variants(types)

  def keyed_variants(module) when is_atom(module) do
    keyed_variants(module.__one_of_types__())
  end

  def keyed_variants(types) when is_list(types) do
    Enum.map(types, fn type -> {member_key(type), type} end)
  end
end
