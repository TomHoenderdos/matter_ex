defmodule Matterlix.Cluster.EthernetNetworkDiagnostics do
  @moduledoc """
  Matter Ethernet Network Diagnostics cluster (0x0037).

  Reports wired Ethernet metrics: PHY rate, duplex, packet errors,
  collision counts. Optional, endpoint 0.
  """

  use Matterlix.Cluster, id: 0x0037, name: :ethernet_network_diagnostics

  # PHYRate: 0=10M, 1=100M, 2=1G, 3=2.5G, 4=5G, 5=10G, etc.
  attribute 0x0000, :phy_rate, :enum8, default: 2
  # FullDuplex
  attribute 0x0001, :full_duplex, :boolean, default: true
  # PacketRxCount
  attribute 0x0002, :packet_rx_count, :uint64, default: 0
  # PacketTxCount
  attribute 0x0003, :packet_tx_count, :uint64, default: 0
  # TxErrCount
  attribute 0x0004, :tx_err_count, :uint64, default: 0
  # CollisionCount
  attribute 0x0005, :collision_count, :uint64, default: 0
  # OverrunCount
  attribute 0x0006, :overrun_count, :uint64, default: 0
  # CarrierDetect: whether link is up
  attribute 0x0007, :carrier_detect, :boolean, default: true
  # TimeSinceReset: seconds since last reset
  attribute 0x0008, :time_since_reset, :uint64, default: 0
  attribute 0xFFFC, :feature_map, :uint32, default: 0x03
  attribute 0xFFFD, :cluster_revision, :uint16, default: 1

  command 0x00, :reset_counts, []

  @impl Matterlix.Cluster
  def handle_command(:reset_counts, _params, state) do
    state = state
      |> set_attribute(:packet_rx_count, 0)
      |> set_attribute(:packet_tx_count, 0)
      |> set_attribute(:tx_err_count, 0)
      |> set_attribute(:collision_count, 0)
      |> set_attribute(:overrun_count, 0)

    {:ok, nil, state}
  end
end
