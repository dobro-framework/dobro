defmodule DobroAi.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dobro-framework/dobro"

  def project do
    [
      app: :dobro_ai,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      description: "AI agent and tool-calling integration for Dobro APIs",
      name: "Dobro AI"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Dobro.AI.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      dobro(:dobro_spec),
      dobro(:dobro_schema),
      dobro(:dobro_domain),
      dobro(:dobro_cqrs),
      dobro(:dobro_ecto),
      {:ecto_sql, "~> 3.10"},
      {:typed_ecto_schema, "~> 0.4.3", runtime: false},
      {:tesla, "~> 1.11"},
      {:jason, "~> 1.2"},
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
      source_url: "#{@source_url}/tree/main/packages/dobro_ai"
    ]
  end
end
