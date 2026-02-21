defmodule Matterlix.Cluster.RelativeHumidityMeasurement do
  @moduledoc """
  Matter Relative Humidity Measurement cluster (0x0405).

  Reports ambient humidity as a percentage with 100ths precision (0-10000).
  Value of 5000 = 50.00% RH.

  Device type 0x0307 (Humidity Sensor).
  """

  use Matterlix.Cluster, id: 0x0405, name: :relative_humidity_measurement

  # MeasuredValue: 0-10000 (100ths of %)
  attribute 0x0000, :measured_value, :uint16, default: 5000
  # MinMeasuredValue
  attribute 0x0001, :min_measured_value, :uint16, default: 0
  # MaxMeasuredValue
  attribute 0x0002, :max_measured_value, :uint16, default: 10000
  # Tolerance
  attribute 0x0003, :tolerance, :uint16, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 3
end
