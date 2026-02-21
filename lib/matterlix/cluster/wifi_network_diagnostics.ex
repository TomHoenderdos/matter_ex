defmodule Matterlix.Cluster.WiFiNetworkDiagnostics do
  @moduledoc """
  Matter Wi-Fi Network Diagnostics cluster (0x0036).

  Reports Wi-Fi connection metrics: BSSID, security type, channel,
  RSSI, beacon counts. Optional, endpoint 0.
  """

  use Matterlix.Cluster, id: 0x0036, name: :wifi_network_diagnostics

  # BSSID: 6-byte MAC
  attribute 0x0000, :bssid, :bytes, default: <<0, 0, 0, 0, 0, 0>>
  # SecurityType: 0=Unspecified, 1=None, 2=WEP, 3=WPA, 4=WPA2, 5=WPA3
  attribute 0x0001, :security_type, :enum8, default: 4
  # WiFiVersion: 0=a, 1=b, 2=g, 3=n, 4=ac, 5=ax, 6=ah
  attribute 0x0002, :wifi_version, :enum8, default: 3
  # ChannelNumber
  attribute 0x0003, :channel_number, :uint16, default: 1
  # RSSI: dBm (-120 to 0)
  attribute 0x0004, :rssi, :int8, default: -50
  # BeaconLostCount
  attribute 0x0005, :beacon_lost_count, :uint32, default: 0
  # BeaconRxCount
  attribute 0x0006, :beacon_rx_count, :uint32, default: 0
  # PacketMulticastRxCount
  attribute 0x0007, :packet_multicast_rx_count, :uint32, default: 0
  # PacketMulticastTxCount
  attribute 0x0008, :packet_multicast_tx_count, :uint32, default: 0
  # PacketUnicastRxCount
  attribute 0x0009, :packet_unicast_rx_count, :uint32, default: 0
  # PacketUnicastTxCount
  attribute 0x000A, :packet_unicast_tx_count, :uint32, default: 0
  # CurrentMaxRate: bps
  attribute 0x000B, :current_max_rate, :uint64, default: 0
  # OverrunCount
  attribute 0x000C, :overrun_count, :uint64, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x03
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :reset_counts, []

  @impl Matterlix.Cluster
  def handle_command(:reset_counts, _params, state) do
    state = state
      |> set_attribute(:beacon_lost_count, 0)
      |> set_attribute(:beacon_rx_count, 0)
      |> set_attribute(:packet_multicast_rx_count, 0)
      |> set_attribute(:packet_multicast_tx_count, 0)
      |> set_attribute(:packet_unicast_rx_count, 0)
      |> set_attribute(:packet_unicast_tx_count, 0)
      |> set_attribute(:overrun_count, 0)

    {:ok, nil, state}
  end
end
