defmodule Matterlix.Cluster.UnitLocalization do
  @moduledoc """
  Matter Unit Localization cluster (0x002D).

  Configures the device's unit system for temperature display.
  TemperatureUnit: 0=Fahrenheit, 1=Celsius, 2=Kelvin.

  Optional on endpoint 0.
  """

  use Matterlix.Cluster, id: 0x002D, name: :unit_localization

  # TemperatureUnit: 0=Fahrenheit, 1=Celsius, 2=Kelvin
  attribute 0x0000, :temperature_unit, :enum8, default: 1, writable: true, enum_values: [0, 1, 2]
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
