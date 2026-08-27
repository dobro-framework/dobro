defmodule Dobro.Igniter.Helpers do
  @moduledoc false

  @doc """
  Igniter 0.8+ returns `{exists?, igniter}` from `module_exists/2`.
  """
  def module_exists(igniter, module) do
    Igniter.Project.Module.module_exists(igniter, module)
  end
end
