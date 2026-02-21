defmodule Matterlix.Cluster.ElectricalMeasurement do
  @moduledoc """
  Matter Electrical Measurement cluster (0x0B04).

  Reports electrical measurements: voltage, current, power (active/reactive/apparent).
  Values are in their respective SI units with scaling factors.

  Device type 0x0510 (Electrical Sensor).
  """

  use Matterlix.Cluster, id: 0x0B04, name: :electrical_measurement

  # MeasurementType: bitmask of active/reactive/apparent/phase/harmonics/power_quality
  attribute 0x0000, :measurement_type, :bitmap32, default: 0x01
  # RmsVoltage: volts (0xFFFF = invalid)
  attribute 0x0505, :rms_voltage, :uint16, default: 230
  # RmsVoltageMin
  attribute 0x0506, :rms_voltage_min, :uint16, default: 220
  # RmsVoltageMax
  attribute 0x0507, :rms_voltage_max, :uint16, default: 240
  # RmsCurrent: amps * 10 (mA precision via multiplier/divisor)
  attribute 0x0508, :rms_current, :uint16, default: 0
  # RmsCurrentMin
  attribute 0x0509, :rms_current_min, :uint16, default: 0
  # RmsCurrentMax
  attribute 0x050A, :rms_current_max, :uint16, default: 160
  # ActivePower: watts * 10
  attribute 0x050B, :active_power, :int16, default: 0
  # ActivePowerMin
  attribute 0x050C, :active_power_min, :int16, default: 0
  # ActivePowerMax
  attribute 0x050D, :active_power_max, :int16, default: 36800
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 3
end
