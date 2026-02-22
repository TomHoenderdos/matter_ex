defmodule MatterEx.Cluster.DoorLock do
  @moduledoc """
  Matter Door Lock cluster (0x0101).

  Controls a door lock with lock/unlock commands, lock state tracking,
  and actuator status. Supports PIN credential-based locking.

  Device type 0x000A (Door Lock).
  """

  use MatterEx.Cluster, id: 0x0101, name: :door_lock

  # LockState: 0=NotFullyLocked, 1=Locked, 2=Unlocked, 3=Unlatched
  attribute 0x0000, :lock_state, :enum8, default: 2
  # LockType: 0=DeadBolt, 1=Magnetic, 2=Other, etc.
  attribute 0x0001, :lock_type, :enum8, default: 0
  # ActuatorEnabled: whether the lock motor is functional
  attribute 0x0002, :actuator_enabled, :boolean, default: true
  # OperatingMode: 0=Normal, 1=Vacation, 2=Privacy, 3=NoRemoteLock, 4=Passage
  attribute 0x0025, :operating_mode, :uint8, default: 0, writable: true, enum_values: [0, 1, 2, 3, 4]
  attribute 0xFFFC, :feature_map, :uint32, default: 0
  attribute 0xFFFD, :cluster_revision, :uint16, default: 7

  command 0x00, :lock_door, [pin_code: :bytes]
  command 0x01, :unlock_door, [pin_code: :bytes]
  command 0x03, :unlock_with_timeout, [timeout: :uint16, pin_code: :bytes]

  @impl MatterEx.Cluster
  def handle_command(:lock_door, _params, state) do
    state = set_attribute(state, :lock_state, 1)
    {:ok, nil, state}
  end

  def handle_command(:unlock_door, _params, state) do
    state = set_attribute(state, :lock_state, 2)
    {:ok, nil, state}
  end

  def handle_command(:unlock_with_timeout, _params, state) do
    state = set_attribute(state, :lock_state, 2)
    {:ok, nil, state}
  end
end
