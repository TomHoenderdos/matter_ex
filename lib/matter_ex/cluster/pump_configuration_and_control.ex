defmodule MatterEx.Cluster.PumpConfigurationAndControl do
  @moduledoc """
  Matter Pump Configuration and Control cluster (0x0200).

  Controls a pump's operating mode, speed, and flow setpoints.
  OperationMode: 0=Normal, 1=Minimum, 2=Maximum, 3=Local.

  Device type 0x0303 (Pump).
  """

  use MatterEx.Cluster, id: 0x0200, name: :pump_configuration_and_control

  # MaxPressure: max pressure in 10ths of kPa (null=unknown)
  attribute 0x0000, :max_pressure, :int16, default: 0
  # MaxSpeed: max impeller speed in RPM (null=unknown)
  attribute 0x0001, :max_speed, :uint16, default: 0
  # MaxFlow: max flow in 10ths of m³/h (null=unknown)
  attribute 0x0002, :max_flow, :uint16, default: 0
  # EffectiveOperationMode: current effective mode
  attribute 0x0011, :effective_operation_mode, :enum8, default: 0
  # EffectiveControlMode: 0=ConstantSpeed, 1=ConstantPressure, 2=ProportionalPressure, etc.
  attribute 0x0012, :effective_control_mode, :enum8, default: 0
  # Capacity: current capacity in 10ths of m³/h
  attribute 0x0013, :capacity, :int16, default: 0
  # OperationMode: 0=Normal, 1=Minimum, 2=Maximum, 3=Local
  attribute 0x0020, :operation_mode, :enum8, default: 0, writable: true, enum_values: [0, 1, 2, 3]
  # ControlMode: writable pump control method
  attribute 0x0021, :control_mode, :enum8, default: 0, writable: true, enum_values: [0, 1, 2, 3, 5, 7]
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 4
end
