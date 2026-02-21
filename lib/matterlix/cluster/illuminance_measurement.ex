defmodule Matterlix.Cluster.IlluminanceMeasurement do
  @moduledoc """
  Matter Illuminance Measurement cluster (0x0400).

  Reports ambient light level. MeasuredValue is 10000 * log10(lux) + 1,
  where 0 = too low to measure, 0xFFFF = invalid.

  Device type 0x0106 (Light Sensor).
  """

  use Matterlix.Cluster, id: 0x0400, name: :illuminance_measurement

  # MeasuredValue: 0 to 0xFFFE (null = 0)
  attribute 0x0000, :measured_value, :uint16, default: 0
  # MinMeasuredValue
  attribute 0x0001, :min_measured_value, :uint16, default: 1
  # MaxMeasuredValue
  attribute 0x0002, :max_measured_value, :uint16, default: 0xFFFE
  # LightSensorType: 0=Photodiode, 1=CMOS, null=unknown
  attribute 0x0004, :light_sensor_type, :enum8, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 3
end
