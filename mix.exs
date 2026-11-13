defmodule ABSmartly.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/absmartly/elixir-sdk"

  def project do
    [
      app: :absmartly,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "ABSmartly SDK for Elixir",
      package: package(),
      docs: docs(),
      name: "ABSmartly",
      source_url: @source_url
    ]
  end

  def application do
    [
      mod: {ABSmartly.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:httpoison, "~> 3.0"},
      {:murmur, "~> 2.0"},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
