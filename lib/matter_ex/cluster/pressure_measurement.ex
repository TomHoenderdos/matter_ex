defmodule MatterEx.Cluster.PressureMeasurement do
  @moduledoc """
  Matter Pressure Measurement cluster (0x0403).

  Reports atmospheric pressure in 10ths of kPa (hPa).
  MeasuredValue of 1013 = 101.3 kPa (standard atmospheric pressure).

  Device type 0x0305 (Pressure Sensor).
  """

  use MatterEx.Cluster, id: 0x0403, name: :pressure_measurement

  # MeasuredValue: pressure in 10ths of kPa
  attribute 0x0000, :measured_value, :int16, default: 1013
  # MinMeasuredValue
  attribute 0x0001, :min_measured_value, :int16, default: 300
  # MaxMeasuredValue
  attribute 0x0002, :max_measured_value, :int16, default: 1100
  # Tolerance
  attribute 0x0003, :tolerance, :uint16, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 3
end
