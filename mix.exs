defmodule MatterEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :matter_ex,
      version: "0.1.0",
      elixir: "~> 1.17",
      description: "A Matter (smart home) protocol stack in pure Elixir",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key]
    ]
  end

  defp deps do
    []
  end
end
