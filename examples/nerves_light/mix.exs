defmodule NervesLight.MixProject do
  use Mix.Project

  @app :nerves_light
  @version "0.1.0"
  @all_targets [:rpi3, :rpi4]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  def application do
    [
      mod: {NervesLight.Application, []},
      extra_applications: [:logger, :runtime_tools, :public_key]
    ]
  end

  defp deps do
    [
      # Nerves
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9"},
      {:ring_logger, "~> 0.11"},
      {:toolshed, "~> 0.4"},

      # Nerves system and networking
      {:nerves_runtime, "~> 0.13", targets: @all_targets},
      {:nerves_pack, "~> 0.7", targets: @all_targets},

      # Target systems
      {:nerves_system_rpi3, "~> 1.27", runtime: false, targets: :rpi3},
      {:nerves_system_rpi4, "~> 1.27", runtime: false, targets: :rpi4},

      # Matter
      {:matter_ex, path: "../../"},

      # BLE (UART transport is built into blue_heron 0.5+)
      {:blue_heron, "~> 0.5", targets: @all_targets},

      # QR code rendering
      {:eqrcode, "~> 0.2"}
    ]
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod || [keep: ["Docs"]]
    ]
  end
end
