defmodule Dobro.Monorepo.MixProject do
  use Mix.Project

  @packages ~w(
    dobro_spec
    dobro_schema
    dobro_domain
    dobro_ecto
    dobro_cqrs
    dobro_runtime
    dobro
    dobro_graphql
    dobro_ai
  )

  def project do
    [
      app: :dobro_monorepo,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      deps: [],
      aliases: aliases()
    ]
  end

  defp aliases do
    [
      test: &test_all/1,
      "dobro.test": &test_all/1,
      "dobro.docs": &docs_all/1
    ]
  end

  defp test_all(_) do
    Enum.each(@packages, fn pkg ->
      Mix.shell().info("\n==> #{pkg}")

      {_, status} =
        System.cmd("mix", ["test"],
          cd: Path.join("packages", pkg),
          into: IO.stream(:stdio, :line),
          stderr_to_stdout: true
        )

      if status != 0, do: Mix.raise("tests failed in #{pkg}")
    end)
  end

  defp docs_all(_) do
    Enum.each(@packages, fn pkg ->
      Mix.shell().info("\n==> docs #{pkg}")

      System.cmd("mix", ["docs"],
        cd: Path.join("packages", pkg),
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )
    end)
  end
end
