defmodule DobroEcto.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dobro-framework/dobro"

  def project do
    [
      app: :dobro_ecto,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      description: "Ecto read/write repositories and query DSL for Dobro",
      name: "Dobro Ecto"
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      dobro(:dobro_spec),
      dobro(:dobro_schema),
      dobro(:dobro_domain),
      {:ecto, "~> 3.1"},
      {:ecto_sql, "~> 3.1"},
      {:postgrex, "~> 0.19 or ~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:typed_ecto_schema, "~> 0.4.3", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp dobro(app) do
    dir = Path.expand("../#{app}", __DIR__)

    if File.dir?(dir) do
      {app, path: "../#{app}"}
    else
      {app, github: "dobro-framework/dobro", sparse: "packages/#{app}", branch: "main"}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE*)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: "#{@source_url}/tree/main/packages/dobro_ecto"
    ]
  end
end
