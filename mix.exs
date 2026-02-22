defmodule MatterEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :matter_ex,
      version: "0.1.0",
      elixir: "~> 1.17",
      description: "A Matter (smart home) protocol stack in pure Elixir",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      source_url: "https://github.com/TomHoenderdos/matter_ex",
      homepage_url: "https://github.com/TomHoenderdos/matter_ex",
      docs: [
        main: "readme",
        extras: ["README.md"]
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/TomHoenderdos/matter_ex"},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key]
    ]
  end

  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
