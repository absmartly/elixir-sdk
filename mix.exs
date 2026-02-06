defmodule ABSmartly.MixProject do
  use Mix.Project

  def project do
    [
      app: :absmartly,
      version: "1.0.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "ABSmartly SDK for Elixir",
      package: package(),
      name: "ABSmartly",
      source_url: "https://github.com/absmartly/elixir-sdk"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:httpoison, "~> 2.0"},
      {:murmur, "~> 2.0"},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/absmartly/elixir-sdk"}
    ]
  end
end
