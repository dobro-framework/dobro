# defmodule Dobro.Infra.TenantQuery do
#   @moduledoc """
#   Infra Tenant Query macro
#   Queries scoped to a tenant
#   """

#   defmacro __using__(port: port) do
#     quote bind_quoted: [port: port] do
#       # @behaviour Dobro.Infra.Query

#       use Dobro.Infra.Query, port: port

#       @moduledoc """
#       Infra Tenant Query module
#       """

#       def execute(input) do
#         raise "Tenant context required"
#       end
#     end
#   end
# end
