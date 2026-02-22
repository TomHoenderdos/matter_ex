defmodule MatterEx.Cluster.OccupancySensing do
  @moduledoc """
  Matter Occupancy Sensing cluster (0x0406).

  Reports occupancy state from PIR, ultrasonic, or physical-contact sensors.
  Occupancy is a bitmap: bit 0 = occupied.

  Device type 0x0107 (Occupancy Sensor).
  """

  use MatterEx.Cluster, id: 0x0406, name: :occupancy_sensing

  # Occupancy: bitmap8 — bit 0 = sensed occupied
  attribute 0x0000, :occupancy, :bitmap8, default: 0
  # OccupancySensorType: 0=PIR, 1=Ultrasonic, 2=PIRAndUltrasonic, 3=PhysicalContact
  attribute 0x0001, :occupancy_sensor_type, :enum8, default: 0
  # OccupancySensorTypeBitmap
  attribute 0x0002, :occupancy_sensor_type_bitmap, :bitmap8, default: 0x01
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 4
end
