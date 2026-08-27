# defmodule Dobro.App.Api.BlockParser do
#   defmodule ParserError do
#     defexception [:message, :line, :file]

#     @impl true
#     def message(exception) do
#       "#{exception.message} at #{exception.file}:#{exception.line}"
#     end
#   end

#   @moduledoc """
#   Parses command/query blocks and builds a pipeline with policy, middleware, and run ast.
#   """

#   # @todo: Add error handling to disallow junk

#   @doc """
#   Parses the provided block to build an API pipeline
#   """
#   def parse(env, {:__block__, _, exprs}) do
#     result = do_parse(env, exprs)
#     validate!(result)
#   end

#   def parse(env, exprs) do
#     result = do_parse(env, exprs)
#     validate!(result)
#   end

#   defp validate!(result) do
#     if !Map.get(result, :policy), do: raise(ParserError, message: "Policy is required")
#     if !Map.get(result, :run), do: raise(ParserError, message: "Run is required")
#     result
#   end

#   defp do_parse(env, exprs) when is_list(exprs) do
#     Enum.reduce(exprs, init(env), &parse_expr/2)
#   end

#   defp do_parse(env, expr) do
#     parse_expr(expr, init(env))
#   end

#   defp init(env),
#     do: %{
#       env: env,
#       middleware: [Dobro.App.Api.Middleware.Logger, Dobro.App.Api.Middleware.Auth],
#       policy: nil,
#       run: nil,
#       mod: nil
#     }

#   def parse_expr({:policy, _, [policy]}, acc) do
#     %{acc | policy: policy}
#   end

#   def parse_expr({:run, _, [opts]}, acc) when is_list(opts) do
#     query_or_cmd_ast = Keyword.get(opts, :query) || Keyword.get(opts, :command)
#     handler_ast = Keyword.fetch!(opts, :handler)

#     query_or_cmd_mod = Macro.expand(query_or_cmd_ast, acc.env)
#     handler_mod = Macro.expand(handler_ast, acc.env)

#     Code.ensure_compiled!(query_or_cmd_mod)
#     Code.ensure_compiled!(handler_mod)

#     result =
#       quote do
#         args = var!(args)
#         context = var!(context)

#         with {:ok, query_or_cmd} <- unquote(query_or_cmd_mod).new(args) do
#           query_or_cmd |> unquote(handler_mod).execute(context)
#         else
#           {:error, pipeline} -> {:error, pipeline}
#         end
#       end

#     %{acc | run: result, mod: query_or_cmd_mod}
#   end

#   def parse_expr({:run, _, [{:context, _, _}, {:args, _, _}, [do: block]]}, acc) do
#     result =
#       quote do
#         args = var!(args)
#         context = var!(context)
#         unquote(block)
#       end

#     %{acc | run: result}
#   end

#   def parse_expr({:middleware, _, [mod]}, acc) do
#     result = Map.get(acc, :middleware, [])
#     result = [result | mod]
#     %{acc | run: result}
#   end

#   def parse_expr(expr, _acc) do
#     raise ParserError,
#           "Invalid syntax: #{Macro.to_string(expr)}"
#   end
# end
