defmodule MatterEx.Cluster.TemperatureMeasurement do
  @moduledoc """
  Matter Temperature Measurement cluster (0x0402).

  Read-only sensor cluster. Values in 0.01°C units (e.g. 2000 = 20.00°C).
  Update measured_value externally via GenServer.call(pid, {:write_attribute, ...}).
  """

  use MatterEx.Cluster, id: 0x0402, name: :temperature_measurement

  attribute 0x0000, :measured_value, :int16, default: 2000
  attribute 0x0001, :min_measured_value, :int16, default: -5000
  attribute 0x0002, :max_measured_value, :int16, default: 12500
  attribute 0x0003, :tolerance, :uint16, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 4
end
