# defmodule Dobro.Infra.Query do
#   @moduledoc """
#   Infra Query macro
#   """

#   defmacro __using__(port: port) do
#     quote bind_quoted: [port: port] do
#       use Dobro.Spec.Adapter, port: port

#       @moduledoc """
#       Infra Query module
#       """
#     end
#   end

#   defmodule Port do
#     defmacro __using__(opts \\ []) do
#       as = Keyword.get(opts, :as)
#       tenant = Keyword.get(opts, :tenant, false)

#       callback_ast =
#         case as do
#           :boolean ->
#             if tenant do
#               quote do: @callback(execute(term(), term()) :: boolean())
#             else
#               quote do: @callback(execute(term()) :: boolean())
#             end

#           :string ->
#             if tenant do
#               quote do: @callback(execute(term(), term()) :: String.t())
#             else
#               quote do: @callback(execute(term()) :: String.t())
#             end

#           nil ->
#             if tenant do
#               quote do: @callback(execute(term(), term()) :: {:ok, term()} | {:error, term()})
#             else
#               quote do: @callback(execute(term()) :: {:ok, term()} | {:error, term()})
#             end

#           _ ->
#             raise "Unsupported: #{as}"
#         end

#       quote location: :keep do
#         @moduledoc """
#         Infra Query Port
#         """

#         unquote(callback_ast)

#         use Dobro.Spec.Port
#       end
#     end
#   end
# end
