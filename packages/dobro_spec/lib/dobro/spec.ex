defmodule Dobro.Spec do
  @moduledoc """
  Ports/Adapters framework
  """
  defmodule Port do
    @moduledoc """
    Marks a module as a Port (interface)
    """
    defmacro __using__(opts \\ []) do
      match = Keyword.get(opts, :match)

      match_ast =
        if is_nil(match) do
          quote do
            alias Dobro.Spec.MatchHelpers

            def __match__, do: &MatchHelpers.default_match/2
          end
        else
          quote do
            def __match__, do: unquote(match)
          end
        end

      quote do
        @doc """
        Resolves an adapter for the current port
        """
        def adapter(adapter_opts \\ []) do
          Dobro.Config.adapter_registry!().resolve!(__MODULE__, adapter_opts)
        end

        @doc """
        Resolves all adapters for the current port
        """
        def all do
          Dobro.Config.adapter_registry!().resolve_all(__MODULE__)
        end

        unquote(match_ast)
      end
    end
  end

  defmodule MatchHelpers do
    @moduledoc """
    Helper functions for matching ports and adapters
    """

    def default_match([], []), do: true

    def default_match(port_opts, adapter_opts)
        when is_list(port_opts) and is_list(adapter_opts) do
      Map.new(port_opts) == Map.new(adapter_opts)
    end
  end

  defmodule Adapter do
    @moduledoc """
    Implements the given Port (interface)
    """

    defmacro __using__(opts \\ []) do
      ports = ports_from_opts!(opts)
      default_for = Keyword.get(opts, :for, [])
      port_for = Keyword.get(opts, :port_for, [])

      behaviour_quotes =
        for port <- ports do
          quote do
            @behaviour unquote(port)
          end
        end

      quote do
        unquote_splicing(behaviour_quotes)

        Module.put_attribute(__MODULE__, :__ports__, unquote(ports))
        Module.put_attribute(__MODULE__, :__port_for__, unquote(port_for))
        Module.put_attribute(__MODULE__, :__for__, unquote(default_for))

        def __ports__, do: @__ports__
        def __port__, do: List.first(@__ports__)
        def __for__, do: @__for__

        def __for__(port) do
          case Keyword.get(@__port_for__, port) do
            nil -> @__for__
            criteria -> criteria
          end
        end
      end
    end

    defp ports_from_opts!(opts) do
      case Keyword.fetch(opts, :ports) do
        {:ok, ports} when is_list(ports) and ports != [] ->
          ports

        _ ->
          case Keyword.fetch(opts, :port) do
            {:ok, port} -> [port]
            :error -> raise ArgumentError, "adapter requires :port or :ports"
          end
      end
    end
  end

  defmodule ConsumerHelpers do
    @moduledoc """
    Helper functions for consumer modules
    """

    def name_from_module(module) do
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom()
    end
  end

  defmodule Consumer do
    @moduledoc """
    When used, defines functions to access the given ports' adapters
    """

    defmacro __using__(opts) do
      ports = Keyword.fetch!(opts, :ports)
      env = __CALLER__

      consumer_functions =
        for port <- ports do
          {port_ast, port_name} =
            case port do
              {name, port_ast} when is_atom(name) ->
                {port_ast, name}

              port_ast ->
                {port_ast, port_ast |> Macro.expand(env) |> ConsumerHelpers.name_from_module()}
            end

          quote do
            def unquote(port_name)(opts \\ []) do
              unquote(port_ast).adapter(opts)
            end
          end
        end

      quote do
        (unquote_splicing(consumer_functions))
      end
    end
  end
end
