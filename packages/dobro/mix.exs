defmodule Dobro.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dobro-framework/dobro"

  def project do
    [
      app: :dobro,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      description:
        "Dobro framework installer and generators — CQRS/DDD with hexagonal architecture",
      name: "Dobro"
    ]
  end

  defp deps do
    [
      dobro(:dobro_spec),
      dobro(:dobro_schema),
      dobro(:dobro_domain),
      dobro(:dobro_ecto),
      dobro(:dobro_cqrs),
      dobro(:dobro_runtime),
      {:igniter, "~> 0.6", optional: true},
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
      source_url: "#{@source_url}/tree/main/packages/dobro"
    ]
  end
end
