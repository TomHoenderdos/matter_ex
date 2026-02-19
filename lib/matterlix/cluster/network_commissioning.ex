defmodule Matterlix.Cluster.NetworkCommissioning do
  @moduledoc """
  Matter Network Commissioning cluster (0x0031).

  Stub implementation for an Ethernet device that is already connected.
  All commands return hardcoded success responses. Endpoint 0 only.
  """

  use Matterlix.Cluster, id: 0x0031, name: :network_commissioning

  attribute 0x0000, :max_networks, :uint8, default: 1
  attribute 0x0001, :networks, :list, default: []
  attribute 0x0002, :scan_max_time_seconds, :uint8, default: 30
  attribute 0x0003, :connect_max_time_seconds, :uint8, default: 30
  attribute 0x0004, :interface_enabled, :boolean, default: true, writable: true
  attribute 0x0005, :last_networking_status, :enum8, default: 0
  attribute 0x0006, :last_network_id, :bytes, default: "ethernet"
  attribute 0x0007, :last_connect_error_value, :int32, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x04
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :scan_networks, [ssid: :bytes, breadcrumb: :uint64]
  command 0x02, :add_or_update_wifi_network, [ssid: :bytes, credentials: :bytes, breadcrumb: :uint64]
  command 0x04, :add_or_update_thread_network, [operational_dataset: :bytes, breadcrumb: :uint64]
  command 0x06, :remove_network, [network_id: :bytes, breadcrumb: :uint64]
  command 0x08, :connect_network, [network_id: :bytes, breadcrumb: :uint64]
  command 0x0A, :reorder_network, [network_id: :bytes, network_index: :uint8, breadcrumb: :uint64]

  @impl Matterlix.Cluster
  def handle_command(:scan_networks, _params, state) do
    # NetworkScanResponse: NetworkingStatus=Success, DebugText=""
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}}, state}
  end

  def handle_command(:add_or_update_wifi_network, _params, state) do
    # NetworkConfigResponse: NetworkingStatus=Success, DebugText="", NetworkIndex=0
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}, 2 => {:uint, 0}}, state}
  end

  def handle_command(:add_or_update_thread_network, _params, state) do
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}, 2 => {:uint, 0}}, state}
  end

  def handle_command(:remove_network, _params, state) do
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}, 2 => {:uint, 0}}, state}
  end

  def handle_command(:connect_network, _params, state) do
    # ConnectNetworkResponse: NetworkingStatus=Success, DebugText="", ErrorValue=null
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}, 2 => :null}, state}
  end

  def handle_command(:reorder_network, _params, state) do
    {:ok, %{0 => {:uint, 0}, 1 => {:string, ""}, 2 => {:uint, 0}}, state}
  end
end
