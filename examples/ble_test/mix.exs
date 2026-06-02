defmodule BleTest.MixProject do
  use Mix.Project

  @app :ble_test
  @version "0.1.0"
  @all_targets [:rpi0_2, :rpi4]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      archives: [nerves_bootstrap: "~> 1.14"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {BleTest.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.10", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.4.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      {:nerves_runtime, "~> 0.13.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Pi Zero 2W system
      {:nerves_system_rpi0_2, "~> 1.31", runtime: false, targets: :rpi0_2},
      {:nerves_system_rpi4, "~> 1.24", runtime: false, targets: :rpi4},

      # GPIO (for BT_REG_ON power-on on Raspberry Pi)
      {:circuits_gpio, "~> 2.0", targets: @all_targets},

      # BlueHeron BLE stack (PR #138 branch with Pi Zero 2W support)
      {:blue_heron,
       path: "/Users/tomhoenderdos/Projects/blue_heron", targets: @all_targets, runtime: false}
    ]
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      applications: [blue_heron: :load],
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  defp listeners(_, _), do: []
end
