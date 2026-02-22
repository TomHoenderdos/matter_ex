defmodule MatterEx.Cluster.FlowMeasurement do
  @moduledoc """
  Matter Flow Measurement cluster (0x0404).

  Reports fluid flow rate in 10ths of m³/h.
  MeasuredValue of 100 = 10.0 m³/h.

  Device type 0x0306 (Flow Sensor).
  """

  use MatterEx.Cluster, id: 0x0404, name: :flow_measurement

  # MeasuredValue: flow in 10ths of m³/h
  attribute 0x0000, :measured_value, :uint16, default: 0
  # MinMeasuredValue
  attribute 0x0001, :min_measured_value, :uint16, default: 0
  # MaxMeasuredValue
  attribute 0x0002, :max_measured_value, :uint16, default: 0xFFFE
  # Tolerance
  attribute 0x0003, :tolerance, :uint16, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 3
end
