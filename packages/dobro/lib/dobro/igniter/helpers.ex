if Code.ensure_loaded?(Igniter) do
  defmodule Dobro.Igniter.Helpers do
    @moduledoc false

    @doc """
    Igniter 0.8+ returns `{exists?, igniter}` from `module_exists/2`.
    """
    def module_exists(igniter, module) do
      Igniter.Project.Module.module_exists(igniter, module)
    end

    @doc """
    Creates a module when missing; otherwise adds a notice and continues.
    """
    def create_module_unless_exists(igniter, module, contents, opts \\ []) do
      case Igniter.Project.Module.module_exists(igniter, module) do
        {true, igniter} ->
          skip_existing_module(igniter, module, opts)

        {false, igniter} ->
          path = Igniter.Project.Module.proper_location(igniter, module)

          if File.exists?(path) do
            skip_existing_module(igniter, module, opts)
          else
            Igniter.Project.Module.create_module(igniter, module, contents, opts)
          end
      end
    end

    defp skip_existing_module(igniter, module, opts) do
      notice =
        Keyword.get(
          opts,
          :notice,
          "#{inspect(module)} already exists — skipped."
        )

      Igniter.add_notice(igniter, notice)
    end

    @doc """
    Returns `{contains?, igniter}` for a substring in the module source.
    """
    def module_source_contains?(igniter, module, needle) when is_binary(needle) do
      case Igniter.Project.Module.find_module(igniter, module) do
        {:ok, {igniter, source, _zipper}} ->
          content = Rewrite.Source.get(source, :content)
          {String.contains?(content, needle), igniter}

        {:error, igniter} ->
          {false, igniter}
      end
    end

    @doc """
    Patches a module when `needle` is absent from its source; otherwise skips with a notice.
    """
    def patch_module_unless_contains(igniter, module, needle, updater, opts \\ []) do
      skip_notice =
        Keyword.get(
          opts,
          :skip_notice,
          "#{inspect(module)} already contains #{inspect(needle)} — skipped patch."
        )

      missing_notice = Keyword.get(opts, :missing_notice)

      case Igniter.Project.Module.module_exists(igniter, module) do
        {false, igniter} ->
          if missing_notice do
            Igniter.add_warning(igniter, missing_notice)
          else
            igniter
          end

        {true, igniter} ->
          case module_source_contains?(igniter, module, needle) do
            {true, igniter} ->
              Igniter.add_notice(igniter, skip_notice)

            {false, igniter} ->
              Igniter.Project.Module.find_and_update_module!(igniter, module, updater)
          end
      end
    end
  end
end
