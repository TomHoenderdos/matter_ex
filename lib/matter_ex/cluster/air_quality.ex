defmodule MatterEx.Cluster.AirQuality do
  @moduledoc """
  Matter Air Quality cluster (0x005B).

  Reports overall air quality as an enum: 0=Unknown, 1=Good, 2=Fair,
  3=Moderate, 4=Poor, 5=VeryPoor, 6=ExtremelyPoor.

  Device type 0x002C (Air Quality Sensor).
  """

  use MatterEx.Cluster, id: 0x005B, name: :air_quality

  # AirQuality: 0=Unknown, 1=Good, 2=Fair, 3=Moderate, 4=Poor, 5=VeryPoor, 6=ExtremelyPoor
  attribute 0x0000, :air_quality, :enum8, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1
end
