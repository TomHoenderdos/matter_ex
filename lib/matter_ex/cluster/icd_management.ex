defmodule MatterEx.Cluster.ICDManagement do
  @moduledoc """
  Matter ICD Management cluster (0x0046).

  Manages Intermittently Connected Device (battery-powered device) behavior.
  Tracks idle/active mode intervals, registered clients for CheckIn messages,
  and operating mode (SIT/LIT).

  Required on endpoint 0 for ICD devices.
  """

  use MatterEx.Cluster, id: 0x0046, name: :icd_management

  # IdleModeDuration: seconds in idle mode before sleeping (SIT: ≤15min, LIT: >15min)
  attribute 0x0000, :idle_mode_duration, :uint32, default: 300
  # ActiveModeDuration: milliseconds to stay active after wake
  attribute 0x0001, :active_mode_duration, :uint32, default: 300
  # ActiveModeThreshold: milliseconds before returning to idle
  attribute 0x0002, :active_mode_threshold, :uint16, default: 300
  # RegisteredClients: list of clients to send CheckIn messages
  attribute 0x0003, :registered_clients, :list, default: []
  # ICDCounter: monotonic counter for CheckIn nonce
  attribute 0x0004, :icd_counter, :uint32, default: 0
  # ClientsSupportedPerFabric
  attribute 0x0005, :clients_supported_per_fabric, :uint16, default: 2
  # UserActiveModeTriggerHint: bitmask of user wake triggers
  attribute 0x0006, :user_active_mode_trigger_hint, :bitmap32, default: 0
  # UserActiveModeTriggerInstruction: human-readable wake instruction
  attribute 0x0007, :user_active_mode_trigger_instruction, :string, default: ""
  # OperatingMode: 0=SIT (Short Idle Time), 1=LIT (Long Idle Time)
  attribute 0x0008, :operating_mode, :enum8, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x01
  attribute 0xFFFD, :cluster_revision, :uint16, default: 2

  command 0x00, :register_client, [
    check_in_node_id: :uint64,
    monitored_subject: :uint64,
    key: :bytes,
    verification_key: :bytes
  ]
  command 0x02, :unregister_client, [check_in_node_id: :uint64, verification_key: :bytes]
  command 0x03, :stay_active_request, [stay_active_duration: :uint32]

  @impl true
  def init(opts) do
    {:ok, state} = super(opts)
    {:ok, state}
  end

  @impl MatterEx.Cluster
  def handle_command(:register_client, params, state) do
    node_id = params[:check_in_node_id] || 0
    subject = params[:monitored_subject] || 0
    key = params[:key] || <<>>

    clients = get_attribute(state, :registered_clients) || []

    # Replace or add client entry
    clients = Enum.reject(clients, &(&1.check_in_node_id == node_id))
    entry = %{check_in_node_id: node_id, monitored_subject: subject, key: key}
    clients = clients ++ [entry]

    state = set_attribute(state, :registered_clients, clients)

    # ICDCounter for response
    counter = get_attribute(state, :icd_counter) || 0
    {:ok, %{0 => {:uint, counter}}, state}
  end

  def handle_command(:unregister_client, params, state) do
    node_id = params[:check_in_node_id] || 0
    clients = get_attribute(state, :registered_clients) || []

    updated = Enum.reject(clients, &(&1.check_in_node_id == node_id))
    state = set_attribute(state, :registered_clients, updated)

    {:ok, nil, state}
  end

  def handle_command(:stay_active_request, params, state) do
    requested = params[:stay_active_duration] || 30_000
    # In a real implementation, the device would stay active for this duration
    # Return the promised active duration (may be less than requested)
    promised = min(requested, 30_000)
    {:ok, %{0 => {:uint, promised}}, state}
  end
end
